#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Full Consistent Backup Script (Mutex-Locked & WAL-Verified)
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================
set -euo pipefail

if [[ -f /etc/default/x-ui ]]; then
    # shellcheck disable=SC1091
    source /etc/default/x-ui
fi

xui_folder="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
xui_db_folder="${XUI_DB_FOLDER:-/etc/x-ui}"
xui_service="${XUI_SERVICE:-/etc/systemd/system}"
backup_root="${XUI_BACKUP_DIR:-/var/backups/x-ui}"
keep_count="${XUI_BACKUP_KEEP:-10}"

stop_service=0
restart_after=0
tag="manual"
quiet=0
no_lock=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop-service)
            stop_service=1
            shift
            ;;
        --restart-after)
            restart_after=1
            shift
            ;;
        --tag)
            tag="${2:-manual}"
            shift 2
            ;;
        --keep)
            keep_count="${2:-10}"
            shift 2
            ;;
        --no-lock)
            no_lock=1
            shift
            ;;
        --quiet|-q)
            quiet=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --stop-service    Stop x-ui before backing up so SQLite WAL is flushed cleanly
  --restart-after   Restart x-ui after backup completes (when used with --stop-service)
  --tag <label>     Label embedded in backup filename (default: manual)
  --keep <N>        Retain the N most recent backups (default: 10, 0 = keep all)
  --quiet, -q       Print only the resulting backup archive path on stdout
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

log_info() {
    [[ "${quiet}" -eq 1 ]] || printf '\033[0;32m[BACKUP]\033[0m %s\n' "$*" >&2
}
log_warn() {
    printf '\033[0;33m[BACKUP-WARN]\033[0m %s\n' "$*" >&2
}
log_err() {
    printf '\033[0;31m[BACKUP-ERR]\033[0m %s\n' "$*" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
    log_err "Please run backup.sh as root."
    exit 1
fi

# ------------------------------------------------------------------------------
# Process Mutex Lock (prevents concurrent backup/update/rollback races)
# ------------------------------------------------------------------------------
if [[ "${no_lock}" -eq 0 ]]; then
    LOCK_DIR="/run/lock"
    [[ -d "${LOCK_DIR}" ]] || LOCK_DIR="/tmp"
    LOCK_FILE="${LOCK_DIR}/x-ui-clean-ops.lock"
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log_err "Another 3X-UI operation (install/update/backup/rollback) is currently running (lock: ${LOCK_FILE})."
        exit 1
    fi
fi

if [[ ! -d "${xui_db_folder}" && ! -d "${xui_folder}" ]]; then
    log_err "Neither ${xui_db_folder} nor ${xui_folder} exists; nothing to back up."
    exit 1
fi

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"

_is_xui_running() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        return 0
    fi
    if pgrep -x x-ui >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_stop_xui_and_verify() {
    log_info "Stopping x-ui service and verifying process termination..."
    systemctl stop x-ui || { log_err "systemctl stop x-ui failed"; return 1; }
    local i
    for i in {1..20}; do
        ! _is_xui_running && return 0
        sleep 1
    done
    log_err "x-ui remains active; refusing inconsistent database copy"
    return 1
}

# Detect current panel version and settings before stopping
cur_ver="unknown"
if [[ -x "${xui_folder}/x-ui" ]]; then
    cur_ver="$("${xui_folder}/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    [[ -n "${cur_ver}" ]] || cur_ver="unknown"
fi

existing_port=""
existing_webBasePath=""
if [[ -x "${xui_folder}/x-ui" ]]; then
    settings_out="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
    existing_port="$(echo "${settings_out}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"
    existing_webBasePath="$(echo "${settings_out}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -n1 || true)"
fi

was_active=0
if _is_xui_running; then
    was_active=1
fi

service_stopped_by_us=0
ts="$(date +%Y%m%d-%H%M%S)"
safe_tag="$(echo "${tag}" | tr -cd 'A-Za-z0-9._-')"
safe_ver="$(echo "${cur_ver}" | tr -cd 'A-Za-z0-9._-')"
archive_name="x-ui-backup-${ts}-v${safe_ver}-${safe_tag}.tar.gz"
archive_path="${backup_root}/${archive_name}"
stage_dir="$(mktemp -d "${backup_root}/.stage-${ts}-XXXXXX")"

cleanup_stage() {
    set +e
    rm -rf "${stage_dir}"
    if [[ "${service_stopped_by_us}" -eq 1 && "${restart_after}" -eq 1 && "${was_active}" -eq 1 ]]; then
        log_info "Restarting x-ui service after backup..."
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null || true
    fi
}
trap cleanup_stage EXIT

log_info "Staging consistent snapshot in ${stage_dir}..."
mkdir -p "${stage_dir}/db" "${stage_dir}/main" "${stage_dir}/system"

# 1. Stage application binaries & service units first (static while running)
if [[ -d "${xui_folder}" ]]; then
    cp -a "${xui_folder}/." "${stage_dir}/main/"
fi
if [[ -f /usr/bin/x-ui ]]; then
    cp -a /usr/bin/x-ui "${stage_dir}/system/x-ui-bin"
fi
if [[ -f /etc/default/x-ui ]]; then
    cp -a /etc/default/x-ui "${stage_dir}/system/default-x-ui"
fi
if [[ -f "${xui_service}/x-ui.service" ]]; then
    cp -a "${xui_service}/x-ui.service" "${stage_dir}/system/x-ui.service"
fi
if [[ -d "${xui_service}/x-ui.service.d" ]]; then
    mkdir -p "${stage_dir}/system/x-ui.service.d"
    cp -a "${xui_service}/x-ui.service.d/." "${stage_dir}/system/x-ui.service.d/"
fi
if [[ -f /etc/init.d/x-ui ]]; then
    cp -a /etc/init.d/x-ui "${stage_dir}/system/x-ui.initd"
fi

# 2. Back up database folder (/etc/x-ui) with strict WAL consistency
if [[ -d "${xui_db_folder}" ]]; then
    # Copy non-SQLite config files in /etc/x-ui (e.g. node_token_key.json)
    for item in "${xui_db_folder}"/*; do
        [[ -e "${item}" ]] || continue
        base_item="$(basename "${item}")"
        case "${base_item}" in
            x-ui.db|x-ui.db-wal|x-ui.db-shm|update-status.json*)
                continue
                ;;
            *)
                cp -a "${item}" "${stage_dir}/db/"
                ;;
        esac
    done

    if [[ -f "${xui_db_folder}/x-ui.db" ]]; then
        online_backup_ok=0
        if [[ "${stop_service}" -eq 0 && "${was_active}" -eq 1 ]]; then
            log_info "Creating SQLite online consistent snapshot without stopping node traffic..."
            if command -v python3 >/dev/null 2>&1; then
                if python3 - "${xui_db_folder}/x-ui.db" "${stage_dir}/db/x-ui.db" <<'PY'
import os, sqlite3, sys
source = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True, timeout=60)
target = sqlite3.connect(sys.argv[2])
try:
    source.backup(target, pages=256, sleep=0.1)
    result = target.execute("PRAGMA integrity_check").fetchone()
    if result != ("ok",):
        raise RuntimeError("SQLite integrity_check failed: " + str(result))
finally:
    target.close()
    source.close()
os.chmod(sys.argv[2], 0o600)
PY
                then
                    online_backup_ok=1
                fi
            elif command -v sqlite3 >/dev/null 2>&1; then
                if sqlite3 -cmd ".timeout 10000" "${xui_db_folder}/x-ui.db" ".backup '${stage_dir}/db/x-ui.db'" && \
                   [[ "$(sqlite3 "${stage_dir}/db/x-ui.db" 'PRAGMA integrity_check;')" == "ok" ]]; then
                    online_backup_ok=1
                fi
            fi
            if [[ "${online_backup_ok}" -ne 1 ]]; then
                rm -f -- "${stage_dir}/db/x-ui.db"
                log_err "Online SQLite backup failed. Refusing unexpected stop of active VLESS/REALITY nodes. Run with --stop-service --restart-after only in a maintenance window."
                exit 1
            fi
        fi

        if [[ "${online_backup_ok}" -eq 0 ]]; then
            if _is_xui_running; then
                [[ "${stop_service}" -eq 1 ]] || { log_err "Unrequested service stop forbidden"; exit 1; }
                service_stopped_by_us=1
                _stop_xui_and_verify
            fi
            # Cold DB + matching WAL files must be copied only after the writer has stopped.
            cp -a "${xui_db_folder}/x-ui.db" "${stage_dir}/db/x-ui.db"
            [[ -f "${xui_db_folder}/x-ui.db-wal" ]] && cp -a "${xui_db_folder}/x-ui.db-wal" "${stage_dir}/db/x-ui.db-wal"
            [[ -f "${xui_db_folder}/x-ui.db-shm" ]] && cp -a "${xui_db_folder}/x-ui.db-shm" "${stage_dir}/db/x-ui.db-shm"
            src_sha="$(sha256sum "${xui_db_folder}/x-ui.db" | awk '{print $1}')"
            dst_sha="$(sha256sum "${stage_dir}/db/x-ui.db" | awk '{print $1}')"
            [[ "${src_sha}" == "${dst_sha}" ]] || { log_err "Cold database copy failed checksum comparison"; exit 1; }
            if command -v python3 >/dev/null 2>&1; then
                python3 - "${stage_dir}/db/x-ui.db" <<'PY'
import sqlite3,sys
db=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro", uri=True)
try:
    result=db.execute("PRAGMA integrity_check").fetchone()
    if result!=("ok",): raise RuntimeError(str(result))
finally: db.close()
PY
            elif command -v sqlite3 >/dev/null 2>&1; then
                [[ "$(sqlite3 "${stage_dir}/db/x-ui.db" 'PRAGMA integrity_check;')" == "ok" ]] || { log_err "Cold backup SQLite integrity failed"; exit 1; }
            else
                log_err "Cannot validate SQLite snapshot; python3/sqlite3 not available"
                exit 1
            fi
        fi
    fi
fi

# 3. Write metadata manifest
db_sha256=""
[[ -f "${stage_dir}/db/x-ui.db" ]] && db_sha256="$(sha256sum "${stage_dir}/db/x-ui.db" | awk '{print $1}')"
bin_sha256=""
[[ -f "${stage_dir}/main/x-ui" ]] && bin_sha256="$(sha256sum "${stage_dir}/main/x-ui" | awk '{print $1}')"

cat > "${stage_dir}/backup-meta.env" <<EOF
BACKUP_TIMESTAMP="${ts}"
BACKUP_CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP_TAG="${safe_tag}"
PANEL_VERSION="${cur_ver}"
PANEL_PORT="${existing_port}"
PANEL_WEB_BASE_PATH="${existing_webBasePath}"
XUI_MAIN_FOLDER="${xui_folder}"
XUI_DB_FOLDER="${xui_db_folder}"
XUI_SERVICE="${xui_service}"
SERVICE_WAS_ACTIVE="${was_active}"
DB_SHA256="${db_sha256}"
BIN_SHA256="${bin_sha256}"
EOF

# 4. Create compressed archive and strictly verify archive integrity
log_info "Creating and verifying backup archive ${archive_path}..."
if ! tar -C "${stage_dir}" -czf "${archive_path}" .; then
    rm -f "${archive_path}"
    log_err "tar failed to create backup archive ${archive_path}!"
    exit 1
fi

if [[ ! -s "${archive_path}" ]]; then
    rm -f "${archive_path}"
    log_err "Backup archive ${archive_path} is empty!"
    exit 1
fi

tar_listing="$(tar -tzf "${archive_path}" 2>/dev/null || true)"
if [[ -z "${tar_listing}" ]]; then
    rm -f "${archive_path}"
    log_err "Backup archive ${archive_path} failed tar -tzf integrity check!"
    exit 1
fi

if [[ -f "${xui_db_folder}/x-ui.db" ]] && ! echo "${tar_listing}" | grep -qE '^\./db/x-ui\.db$'; then
    rm -f "${archive_path}"
    log_err "Backup archive is missing ./db/x-ui.db!"
    exit 1
fi

if ! echo "${tar_listing}" | grep -qE '^\./backup-meta\.env$'; then
    rm -f "${archive_path}"
    log_err "Backup archive is missing ./backup-meta.env!"
    exit 1
fi

chmod 600 "${archive_path}"
(cd "${backup_root}" && sha256sum "${archive_name}" > "${archive_name}.sha256")
chmod 600 "${archive_path}.sha256"
ln -sfn "${archive_path}" "${backup_root}/latest.tar.gz"
ln -sfn "${archive_path}.sha256" "${backup_root}/latest.tar.gz.sha256"

# 5. Prune old backups if keep_count > 0
if [[ "${keep_count}" =~ ^[0-9]+$ && "${keep_count}" -gt 0 ]]; then
    mapfile -t archives < <(find "${backup_root}" -maxdepth 1 -type f -name 'x-ui-backup-*.tar.gz' | sort -r)
    if [[ "${#archives[@]}" -gt "${keep_count}" ]]; then
        for old_archive in "${archives[@]:${keep_count}}"; do
            log_info "Pruning old backup: $(basename "${old_archive}")"
            rm -f "${old_archive}" "${old_archive}.sha256"
        done
    fi
fi

log_info "Backup completed and verified: ${archive_path}"
printf '%s\n' "${archive_path}"
