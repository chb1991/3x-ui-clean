#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Atomic Rollback & Full Verification Script
# CLEAN_SCRIPT_PROTOCOL=2
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
staging_root="${XUI_STAGING_DIR:-/var/tmp}"

target_archive=""
auto_mode=0
skip_db=0
no_lock=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            target_archive="${backup_root}/latest.tar.gz"
            shift
            ;;
        --auto)
            target_archive="${2:-${backup_root}/latest.tar.gz}"
            auto_mode=1
            shift
            [[ $# -gt 0 && "$1" != --* ]] && shift || true
            ;;
        --file|-f)
            target_archive="${2:-}"
            shift 2
            ;;
        --binary-only)
            skip_db=1
            shift
            ;;
        --no-lock)
            no_lock=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --latest              Restore from the most recent backup (${backup_root}/latest.tar.gz)
  --file, -f <path>     Restore from a specific backup .tar.gz archive
  --auto [path]         Non-interactive rollback (used by update.sh on failure)
  --binary-only         Restore only /usr/local/x-ui and service units, keeping current /etc/x-ui/x-ui.db
  --no-lock             Skip acquiring mutex lock (when called by parent holding lock)
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

log_info() { printf '\033[0;32m[ROLLBACK]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[0;33m[ROLLBACK-WARN]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[0;31m[ROLLBACK-ERR]\033[0m %s\n' "$*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
    log_err "Please run rollback.sh as root."
    exit 1
fi

# ------------------------------------------------------------------------------
# Process Mutex Lock
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
    log_info "Stopping x-ui and verifying process termination..."
    systemctl stop x-ui || { log_err "systemctl stop x-ui failed; refusing to restore live database"; return 1; }
    local i
    for i in {1..20}; do
        ! _is_xui_running && return 0
        sleep 1
    done
    log_err "x-ui process still exists after stop; refusing to overwrite database"
    return 1
}

# Interactive selection if no archive was specified
if [[ -z "${target_archive}" ]]; then
    if [[ ! -d "${backup_root}" ]]; then
        log_err "Backup directory ${backup_root} does not exist."
        exit 1
    fi
    mapfile -t archives < <(find "${backup_root}" -maxdepth 1 -type f -name 'x-ui-backup-*.tar.gz' | sort -r)
    if [[ "${#archives[@]}" -eq 0 ]]; then
        log_err "No backup archives found in ${backup_root}."
        exit 1
    fi
    echo "Available 3X-UI backups in ${backup_root}:"
    for i in "${!archives[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "$(basename "${archives[$i]}")"
    done
    echo ""
    read -rp "Select backup number to restore [1-${#archives[@]}] (or 0 to cancel): " choice
    if [[ ! "${choice}" =~ ^[0-9]+$ || "${choice}" -eq 0 ]]; then
        log_info "Rollback cancelled."
        exit 0
    fi
    if [[ "${choice}" -lt 1 || "${choice}" -gt "${#archives[@]}" ]]; then
        log_err "Invalid selection."
        exit 1
    fi
    target_archive="${archives[$((choice - 1))]}"
fi

if [[ -L "${target_archive}" ]]; then
    target_archive="$(readlink -f "${target_archive}")"
fi

if [[ ! -f "${target_archive}" ]]; then
    log_err "Backup archive not found: ${target_archive}"
    exit 1
fi

# Verify SHA256 if sidecar file exists
if [[ ! -f "${target_archive}.sha256" ]]; then
    log_err "Missing verified backup checksum sidecar; refusing unverified rollback"
    exit 1
fi
if [[ -f "${target_archive}.sha256" ]]; then
    log_info "Verifying SHA256 checksum for $(basename "${target_archive}")..."
    if ! (cd "$(dirname "${target_archive}")" && sha256sum -c "$(basename "${target_archive}.sha256")" >/dev/null 2>&1); then
        log_err "SHA256 verification failed for ${target_archive}! Aborting rollback."
        exit 1
    fi
fi

# Verify archive stream before extracting
if ! tar -tzf "${target_archive}" >/dev/null 2>&1; then
    log_err "Archive ${target_archive} is corrupted (tar -tzf failed)! Aborting rollback."
    exit 1
fi

install -d -m 700 "${staging_root}"
free_kib="$(df -Pk "${staging_root}" | awk 'NR == 2 {print $4}')"
[[ "${free_kib}" =~ ^[0-9]+$ && "${free_kib}" -ge 262144 ]] || { log_err "Need at least 256 MiB on disk-backed staging"; exit 1; }
stage_dir="$(mktemp -d "${staging_root}/x-ui-rollback-XXXXXX")"
trap 'rm -rf "${stage_dir}"' EXIT

log_info "Extracting backup archive $(basename "${target_archive}")..."
tar -C "${stage_dir}" -xzf "${target_archive}"
[[ -s "${stage_dir}/db/x-ui.db" && -s "${stage_dir}/main/x-ui" && -f "${stage_dir}/backup-meta.env" ]] || {
    log_err "Backup missing required SQLite DB, binary or manifest"; exit 1;
}

PANEL_VERSION=""
PANEL_PORT=""
BACKUP_CREATED_UTC=""
DB_SHA256=""
BIN_SHA256=""

if [[ -f "${stage_dir}/backup-meta.env" ]]; then
    # shellcheck disable=SC1090
    source "${stage_dir}/backup-meta.env"
    log_info "Backup Metadata: Version=${PANEL_VERSION:-unknown}, Port=${PANEL_PORT:-unknown}, Created=${BACKUP_CREATED_UTC:-unknown}"
fi

if [[ "${auto_mode}" -eq 0 ]]; then
    read -rp "Confirm restoring this backup? This will stop x-ui and restore files [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelled."
        exit 0
    fi
fi

# Restore only after all archive checks are complete, never touch an active SQLite DB.
[[ "${xui_folder}" == "/usr/local/x-ui" ]] || { log_err "Unexpected installation directory; refusing destructive restore"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log_err "python3 required for SQLite integrity validation"; exit 1; }
python3 - "${stage_dir}/db/x-ui.db" <<'PY'
import sqlite3,sys
db=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro", uri=True, timeout=15)
try:
    value=db.execute("PRAGMA integrity_check").fetchone()[0]
    if value != "ok": raise RuntimeError("PRAGMA integrity_check: "+str(value))
finally: db.close()
PY
_stop_xui_and_verify

# 1. Restore database folder (/etc/x-ui) unless --binary-only
if [[ "${skip_db}" -eq 0 && -d "${stage_dir}/db" ]]; then
    log_info "Restoring database directory ${xui_db_folder}..."
    mkdir -p "${xui_db_folder}"
    # Remove current WAL/SHM files before restoring so stale WAL frames cannot corrupt the restored DB
    rm -f "${xui_db_folder}/x-ui.db-wal" "${xui_db_folder}/x-ui.db-shm"
    cp -a "${stage_dir}/db/." "${xui_db_folder}/"
    chmod 600 "${xui_db_folder}/x-ui.db" 2>/dev/null || true

    # Verify restored DB hash and SQLite integrity
    if [[ -f "${xui_db_folder}/x-ui.db" ]]; then
        if [[ -n "${DB_SHA256}" ]]; then
            restored_db_sha="$(sha256sum "${xui_db_folder}/x-ui.db" | awk '{print $1}')"
            if [[ "${restored_db_sha}" != "${DB_SHA256}" ]]; then
                log_err "Restored database SHA256 mismatch (expected ${DB_SHA256}, got ${restored_db_sha})!"
                exit 1
            fi
            log_info "Database SHA256 verified (${restored_db_sha::16}...)."
        fi
        if command -v sqlite3 >/dev/null 2>&1; then
            db_integrity="$(sqlite3 "${xui_db_folder}/x-ui.db" "PRAGMA integrity_check;" 2>/dev/null | head -n1 || true)"
            if [[ "${db_integrity}" != "ok" ]]; then
                log_err "Restored SQLite database failed PRAGMA integrity_check: ${db_integrity}"
                exit 1
            fi
            log_info "SQLite PRAGMA integrity_check: ok"
        fi
    fi
fi

# 2. Restore main folder (/usr/local/x-ui)
if [[ -d "${stage_dir}/main" ]]; then
    log_info "Restoring application directory ${xui_folder}..."
    mkdir -p "${xui_folder}"
    find "${xui_folder}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    cp -a "${stage_dir}/main/." "${xui_folder}/"
    chmod +x "${xui_folder}/x-ui" "${xui_folder}/x-ui.sh" 2>/dev/null || true
    chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true
    chown -R root:root "${xui_folder}" 2>/dev/null || true

    if [[ -n "${BIN_SHA256}" && -f "${xui_folder}/x-ui" ]]; then
        restored_bin_sha="$(sha256sum "${xui_folder}/x-ui" | awk '{print $1}')"
        if [[ "${restored_bin_sha}" != "${BIN_SHA256}" ]]; then
            log_err "Restored x-ui binary SHA256 mismatch (expected ${BIN_SHA256}, got ${restored_bin_sha})!"
            exit 1
        fi
        log_info "Binary SHA256 verified (${restored_bin_sha::16}...)."
    fi
fi

# 3. Restore CLI script and systemd service unit
if [[ -f "${stage_dir}/system/x-ui-bin" ]]; then
    cp -a "${stage_dir}/system/x-ui-bin" /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
fi
if [[ -f "${stage_dir}/system/default-x-ui" ]]; then
    cp -a "${stage_dir}/system/default-x-ui" /etc/default/x-ui
fi
if [[ -f "${stage_dir}/system/x-ui.service" ]]; then
    cp -a "${stage_dir}/system/x-ui.service" "${xui_service}/x-ui.service"
fi
if [[ -d "${xui_service}/x-ui.service.d" ]]; then
    find "${xui_service}/x-ui.service.d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
if [[ -d "${stage_dir}/system/x-ui.service.d" ]]; then
    mkdir -p "${xui_service}/x-ui.service.d"
    cp -a "${stage_dir}/system/x-ui.service.d/." "${xui_service}/x-ui.service.d/"
fi
if [[ -f "${stage_dir}/system/x-ui.initd" ]]; then
    cp -a "${stage_dir}/system/x-ui.initd" /etc/init.d/x-ui
    chmod +x /etc/init.d/x-ui
fi

# 4. Verify restored binary can read restored database settings
check_port="${PANEL_PORT}"
if [[ -x "${xui_folder}/x-ui" ]]; then
    settings_check="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
    if [[ -z "${settings_check}" ]]; then
        log_err "Restored x-ui binary failed to read settings from ${xui_db_folder}/x-ui.db!"
        exit 1
    fi
    if [[ -z "${check_port}" ]]; then
        check_port="$(echo "${settings_check}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"
    fi
fi

# 5. Start service and verify both systemd status and listening port
log_info "Reloading service manager and starting x-ui..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable x-ui 2>/dev/null || true
    systemctl start x-ui
else
    rc-service x-ui restart
fi

healthy=0
for _ in 1 2 3 4 5; do
    sleep 2
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet x-ui; then
            continue
        fi
    fi
    if [[ -n "${check_port}" ]] && command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -qE ":${check_port}\\b"; then
            healthy=1
            break
        fi
    else
        healthy=1
        break
    fi
done

if [[ "${healthy}" -ne 1 ]]; then
    log_err "Rollback health check failed: x-ui service is not active or port ${check_port:-unknown} is not listening! Check: journalctl -u x-ui -n 50"
    exit 1
fi

log_info "Rollback succeeded! Database, binaries, and panel service (port ${check_port:-ok}) are fully verified."
