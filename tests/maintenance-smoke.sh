#!/usr/bin/env bash
# Non-production fault checks against fake x-ui paths and a fake systemctl.
set -Eeuo pipefail
[[ "${EUID}" -eq 0 ]] || { echo 'Test must run as root in ephemeral CI runner' >&2; exit 1; }

T="$(mktemp -d /var/tmp/xui-clean-smoke-XXXXXXXX)"
WRITER_PID=''
cleanup() {
    [[ -z "${WRITER_PID}" ]] || { kill "${WRITER_PID}" 2>/dev/null || true; wait "${WRITER_PID}" 2>/dev/null || true; }
    rm -rf -- "${T}"
}
trap cleanup EXIT

mkdir -p "${T}/db" "${T}/app/bin" "${T}/bin" "${T}/backups"
export XUI_MAIN_FOLDER="${T}/app"
export XUI_DB_FOLDER="${T}/db"
export XUI_BACKUP_DIR="${T}/backups"
export XUI_STAGING_DIR="${T}"
export TEST_STOP_LOG="${T}/UNEXPECTED_STOP"

cat > "${T}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    is-active) exit 0 ;;
    stop) touch "${TEST_STOP_LOG}"; exit 99 ;;
    *) exit 0 ;;
esac
SH
chmod +x "${T}/bin/systemctl"
export PATH="${T}/bin:${PATH}"

cat > "${T}/app/x-ui" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -v) echo '3.11.0' ;;
  setting) printf 'port: 38627\nwebBasePath: /custom/\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "${T}/app/x-ui"
printf '{"inbounds":[]}' > "${T}/app/bin/config.json"

# Keep the SQLite WAL actively changing while backup.sh copies an online snapshot.
python3 - "${T}/db/x-ui.db" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute('PRAGMA journal_mode=WAL')
db.execute('CREATE TABLE counters (n INTEGER NOT NULL)')
db.execute('INSERT INTO counters VALUES (0)')
db.commit()
db.close()
PY

python3 - "${T}/db/x-ui.db" <<'PY' &
import sqlite3,sys,time
db=sqlite3.connect(sys.argv[1],timeout=20)
for i in range(200):
    db.execute('INSERT INTO counters VALUES (?)',(i+1,))
    db.commit()
    time.sleep(0.01)
db.close()
PY
WRITER_PID="$!"
sleep 0.1
archive="$(bash scripts/backup.sh --keep 0 --quiet)"
[[ -s "${archive}" && -f "${archive}.sha256" ]] || { echo 'Backup archive missing' >&2; exit 1; }
[[ ! -e "${TEST_STOP_LOG}" ]] || { echo 'Online backup unexpectedly stopped x-ui' >&2; exit 1; }
tar -xOf "${archive}" ./db/x-ui.db > "${T}/snapshot.db"
python3 - "${T}/snapshot.db" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
assert db.execute('SELECT COUNT(*) FROM counters').fetchone()[0]>0
db.close()
PY
echo 'PASS: online SQLite WAL backup consistent without stopping service'

# Verify that missing offline archive checksum aborts before systemctl stop.
: > "${T}/missing-sidecar.tar.gz"
set +e
output="$(bash scripts/update.sh --yes --offline "${T}/missing-sidecar.tar.gz" 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || { echo 'Updater accepted unsigned archive' >&2; exit 1; }
grep -q 'Missing offline .sha256 sidecar' <<< "${output}" || { echo "${output}" >&2; exit 1; }
[[ ! -e "${TEST_STOP_LOG}" ]] || { echo 'Preflight stopped service' >&2; exit 1; }
echo 'PASS: unsigned update package rejected before downtime'

# Restore must reject a corrupted checksum without stopping the service.
echo 'corrupt backup' > "${T}/damaged.tar.gz"
printf '%064d  damaged.tar.gz\n' 0 > "${T}/damaged.tar.gz.sha256"
set +e
output="$(bash scripts/rollback.sh --file "${T}/damaged.tar.gz" 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || { echo 'Rollback accepted tampered archive' >&2; exit 1; }
[[ ! -e "${TEST_STOP_LOG}" ]] || { echo 'Rollback preflight stopped service' >&2; exit 1; }
echo 'PASS: corrupt rollback rejected before downtime'

# A fully checksummed offline bundle must still abort safely if systemctl stop fails.
# The fake systemctl above deliberately returns 99 and logs attempts to stop.
kill "${WRITER_PID}" 2>/dev/null || true
wait "${WRITER_PID}" 2>/dev/null || true
WRITER_PID=''
old_bin_hash="$(sha256sum "${T}/app/x-ui" | cut -d' ' -f1)"
old_db_hash="$(sha256sum "${T}/db/x-ui.db" | cut -d' ' -f1)"
mkdir -p "${T}/fake-package/x-ui/bin" "${T}/bundle/3x-ui-clean-offline/scripts"
cp "${T}/app/x-ui" "${T}/fake-package/x-ui/x-ui"
cp "${T}/app/bin/config.json" "${T}/fake-package/x-ui/bin/config.json"
cp scripts/rollback.sh "${T}/bundle/3x-ui-clean-offline/scripts/"
(
    cd "${T}/fake-package"
    tar -czf "${T}/bundle/3x-ui-clean-offline/x-ui-linux-amd64.tar.gz" x-ui
)
(
    cd "${T}/bundle/3x-ui-clean-offline"
    sha256sum x-ui-linux-amd64.tar.gz > x-ui-linux-amd64.tar.gz.sha256
)
(
    cd "${T}/bundle"
    tar -czf "${T}/checksummed-bundle.tar.gz" 3x-ui-clean-offline
)
(
    cd "${T}"
    sha256sum checksummed-bundle.tar.gz > checksummed-bundle.tar.gz.sha256
)
set +e
output="$(bash scripts/update.sh --yes --offline "${T}/checksummed-bundle.tar.gz" 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || { echo 'Updater continued after failed systemctl stop' >&2; exit 1; }
[[ -e "${TEST_STOP_LOG}" ]] || { echo "Stop failure path was not exercised: ${output}" >&2; exit 1; }
[[ "$(sha256sum "${T}/app/x-ui" | cut -d' ' -f1)" == "${old_bin_hash}" ]] || {
    echo 'Original binary changed despite failed stop' >&2; exit 1;
}
[[ "$(sha256sum "${T}/db/x-ui.db" | cut -d' ' -f1)" == "${old_db_hash}" ]] || {
    echo 'Original database changed despite failed stop' >&2; exit 1;
}
echo 'PASS: failed systemctl stop leaves original binary and database untouched'
