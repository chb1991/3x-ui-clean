#!/usr/bin/env bash
# Run ONLY inside an ephemeral Debian 13 container.
# Simulate a production migration failure and assert original app + WAL SQLite restore.
set -Eeuo pipefail
[[ -f /etc/debian_version ]] || { echo "No Debian environment"; exit 1; }
grep -q '^13' /etc/debian_version || { echo "Must run in Debian 13"; exit 1; }
test ! -e /etc/x-ui/x-ui.db || { echo "Refusing to touch pre-existing x-ui"; exit 1; }
umask 077
mkdir -p /etc/x-ui /usr/local/x-ui/bin /etc/systemd/system/x-ui.service.d /var/backups/x-ui /var/tmp /tmp/fake-bin
printf 'OLD-EXACT-REALITY-CONFIG\n' > /usr/local/x-ui/bin/config.json
printf 'OLD-SYSTEMD-UNIT\n' > /etc/systemd/system/x-ui.service
printf 'OLD-DROPIN\n' > /etc/systemd/system/x-ui.service.d/10-xui-sandbox.conf

cat >/usr/local/x-ui/x-ui <<'OLD'
#!/usr/bin/env bash
case "${1:-}" in
  -v) echo '3.11.0';;
  setting) printf 'port: 38627\nwebBasePath: /original-base/\nlistenIP: 127.0.0.1\n';;
  migrate) exit 0;;
  *) exit 0;;
esac
OLD
chmod +x /usr/local/x-ui/x-ui
cp /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh
cat >/usr/bin/x-ui <<'SH'
#!/bin/sh
exit 0
SH
chmod +x /usr/bin/x-ui
cat >/tmp/fake-bin/systemctl <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  is-active)
    [[ -f /tmp/fake-service-active ]]
    ;;
  stop)
    rm -f /tmp/fake-service-active
    ;;
  start|restart)
    touch /tmp/fake-service-active
    ;;
  *)
    exit 0
    ;;
esac
SH
cat >/tmp/fake-bin/ss <<'SH'
#!/bin/sh
echo 'LISTEN 0 4096 127.0.0.1:38627 0.0.0.0:*'
SH
chmod +x /tmp/fake-bin/systemctl /tmp/fake-bin/ss
touch /tmp/fake-service-active
export PATH="/tmp/fake-bin:${PATH}"
python3 - <<'PY'
import sqlite3
conn=sqlite3.connect('/etc/x-ui/x-ui.db')
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('CREATE TABLE secrets(k TEXT PRIMARY KEY,v TEXT)')
conn.execute('INSERT INTO secrets VALUES (?,?)',('REALITY','keep-this-key'))
conn.commit()
conn.close()
PY
original_db_rows="$(python3 - <<'PY'
import sqlite3
conn=sqlite3.connect('/etc/x-ui/x-ui.db')
print(conn.execute('SELECT COUNT(*) FROM secrets').fetchone()[0])
conn.close()
PY
)"
original_bin_sha="$(sha256sum /usr/local/x-ui/x-ui | cut -d' ' -f1)"
original_conf_sha="$(sha256sum /usr/local/x-ui/bin/config.json | cut -d' ' -f1)"

mkdir -p /tmp/pkg/x-ui/bin /tmp/bundle/3x-ui-clean-offline/scripts
cat >/tmp/pkg/x-ui/x-ui <<'NEW'
#!/usr/bin/env bash
case "${1:-}" in
  -v) echo '3.11.0';;
  setting) printf 'port: 38627\nwebBasePath: /original-base/\nlistenIP: 127.0.0.1\n';;
  migrate) echo 'INTENTIONAL TEST MIGRATION FAILURE' >&2; exit 67;;
  *) exit 0;;
esac
NEW
chmod +x /tmp/pkg/x-ui/x-ui
cat >/tmp/pkg/x-ui/x-ui.sh <<'SH'
#!/bin/sh
echo NEW
SH
chmod +x /tmp/pkg/x-ui/x-ui.sh
echo NEW-CONFIG-SHOULD-NOT-BE-INSTALLED > /tmp/pkg/x-ui/bin/config.json
printf 'NEW-UNIT\n' > /tmp/pkg/x-ui/x-ui.service.debian
cp scripts/*.sh /tmp/bundle/3x-ui-clean-offline/scripts/
(cd /tmp/pkg && tar -czf /tmp/bundle/3x-ui-clean-offline/x-ui-linux-amd64.tar.gz x-ui)
(cd /tmp/bundle/3x-ui-clean-offline && sha256sum x-ui-linux-amd64.tar.gz > x-ui-linux-amd64.tar.gz.sha256)
(cd /tmp/bundle && tar -czf /var/tmp/simulated-clean-release.tar.gz 3x-ui-clean-offline)
(cd /var/tmp && sha256sum simulated-clean-release.tar.gz > simulated-clean-release.tar.gz.sha256)

set +e
NONINTERACTIVE=1 bash scripts/update.sh --offline /var/tmp/simulated-clean-release.tar.gz --yes >/tmp/simulated-upgrade.log 2>&1
status=$?
set -e
[[ "${status}" -ne 0 ]] || { echo 'Expected migration failure was not reported'; exit 1; }
grep -q 'INTENTIONAL TEST MIGRATION FAILURE' /tmp/simulated-upgrade.log || { cat /tmp/simulated-upgrade.log; exit 1; }
grep -q 'Restor' /tmp/simulated-upgrade.log || { cat /tmp/simulated-upgrade.log; exit 1; }

[[ "$(sha256sum /usr/local/x-ui/x-ui | cut -d' ' -f1)" == "${original_bin_sha}" ]] || { echo 'Original app binary was not restored'; cat /tmp/simulated-upgrade.log; exit 1; }
[[ "$(sha256sum /usr/local/x-ui/bin/config.json | cut -d' ' -f1)" == "${original_conf_sha}" ]] || { echo 'Original Xray config was not restored'; exit 1; }
[[ "$(cat /etc/systemd/system/x-ui.service)" == 'OLD-SYSTEMD-UNIT' ]] || { echo 'Original systemd service not restored'; exit 1; }
[[ "$(cat /etc/systemd/system/x-ui.service.d/10-xui-sandbox.conf)" == 'OLD-DROPIN' ]] || { echo 'Original service drop-in not restored'; exit 1; }
[[ -f /tmp/fake-service-active ]] || { echo 'Original panel service not restarted'; cat /tmp/simulated-upgrade.log; exit 1; }
python3 - <<'PY'
import sqlite3
conn=sqlite3.connect('/etc/x-ui/x-ui.db')
assert conn.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
assert conn.execute('SELECT v FROM secrets WHERE k=?',('REALITY',)).fetchone()[0] == 'keep-this-key'
conn.close()
PY
[[ -f /var/backups/x-ui/latest.tar.gz ]] || { echo 'Upgrade backup not persisted'; exit 1; }
echo 'PASS: Debian 13 migration failure caused rollback; SQLite, REALITY, binary, systemd files and service preserved'
