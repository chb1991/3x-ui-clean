#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Full Consistent Backup Script (SQLite WAL-Safe + Binaries + Unit)
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================
set -euo pipefail

# Load custom paths if configured in /etc/default/x-ui
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

if [[ ! -d "${xui_db_folder}" && ! -d "${xui_folder}" ]]; then
    log_err "Neither ${xui_db_folder} nor ${xui_folder} exists; nothing to back up."
    exit 1
fi

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"

# Detect current panel version and settings before stopping
cur_ver="unknown"
if [[ -x "${xui_folder}/x-ui" ]]; then
    cur_ver="$("${xui_folder}/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || echo 'unknown')"
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
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
    was_active=1
fi

if [[ "${stop_service}" -eq 1 && "${was_active}" -eq 1 ]]; then
    log_info "Stopping x-ui service to flush SQLite WAL state..."
    systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null || true
fi

ts="$(date +%Y%m%d-%H%M%S)"
safe_tag="$(echo "${tag}" | tr -cd 'A-Za-z0-9._-')"
safe_ver="$(echo "${cur_ver}" | tr -cd 'A-Za-z0-9._-')"
archive_name="x-ui-backup-${ts}-v${safe_ver}-${safe_tag}.tar.gz"
archive_path="${backup_root}/${archive_name}"
stage_dir="$(mktemp -d "${backup_root}/.stage-${ts}-XXXXXX")"

cleanup_stage() {
    rm -rf "${stage_dir}"
    if [[ "${stop_service}" -eq 1 && "${restart_after}" -eq 1 && "${was_active}" -eq 1 ]]; then
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null || true
    fi
}
trap cleanup_stage EXIT

log_info "Staging consistent snapshot in ${stage_dir}..."
mkdir -p "${stage_dir}/db" "${stage_dir}/main" "${stage_dir}/system"

# 1. Back up database folder (/etc/x-ui)
if [[ -d "${xui_db_folder}" ]]; then
    cp -a "${xui_db_folder}/." "${stage_dir}/db/"
    # If service is still running (live backup) and sqlite3 CLI is present, also create an online atomic .backup copy
    if [[ "${stop_service}" -eq 0 && -f "${xui_db_folder}/x-ui.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
        log_info "Running sqlite3 online backup API for live WAL consistency..."
        if sqlite3 "${xui_db_folder}/x-ui.db" ".backup '${stage_dir}/db/x-ui.db.atomic'" 2>/dev/null; then
            mv -f "${stage_dir}/db/x-ui.db.atomic" "${stage_dir}/db/x-ui.db"
            rm -f "${stage_dir}/db/x-ui.db-wal" "${stage_dir}/db/x-ui.db-shm"
        fi
    fi
fi

# 2. Back up main folder (/usr/local/x-ui)
if [[ -d "${xui_folder}" ]]; then
    cp -a "${xui_folder}/." "${stage_dir}/main/"
fi

# 3. Back up CLI wrapper, env file, and service units
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

# 4. Write metadata manifest
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

# 5. Create compressed archive and SHA256 checksum
tar -C "${stage_dir}" -czf "${archive_path}" .
chmod 600 "${archive_path}"
(cd "${backup_root}" && sha256sum "${archive_name}" > "${archive_name}.sha256")
chmod 600 "${archive_path}.sha256"
ln -sfn "${archive_path}" "${backup_root}/latest.tar.gz"
ln -sfn "${archive_path}.sha256" "${backup_root}/latest.tar.gz.sha256"

# 6. Prune old backups if keep_count > 0
if [[ "${keep_count}" =~ ^[0-9]+$ && "${keep_count}" -gt 0 ]]; then
    mapfile -t archives < <(find "${backup_root}" -maxdepth 1 -type f -name 'x-ui-backup-*.tar.gz' | sort -r)
    if [[ "${#archives[@]}" -gt "${keep_count}" ]]; then
        for old_archive in "${archives[@]:${keep_count}}"; do
            log_info "Pruning old backup: $(basename "${old_archive}")"
            rm -f "${old_archive}" "${old_archive}.sha256"
        done
    fi
fi

log_info "Backup completed successfully: ${archive_path}"
printf '%s\n' "${archive_path}"
