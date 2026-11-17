#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Atomic Rollback & Recovery Script
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

target_archive=""
auto_mode=0
skip_db=0

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
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --latest              Restore from the most recent backup (${backup_root}/latest.tar.gz)
  --file, -f <path>     Restore from a specific backup .tar.gz archive
  --auto [path]         Non-interactive rollback (used by update.sh on failure)
  --binary-only         Restore only /usr/local/x-ui and service units, keeping current /etc/x-ui/x-ui.db
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
if [[ -f "${target_archive}.sha256" ]]; then
    log_info "Verifying SHA256 checksum for $(basename "${target_archive}")..."
    if ! (cd "$(dirname "${target_archive}")" && sha256sum -c "$(basename "${target_archive}.sha256")" >/dev/null 2>&1); then
        log_err "SHA256 verification failed for ${target_archive}! Aborting rollback."
        exit 1
    fi
fi

stage_dir="$(mktemp -d "/tmp/x-ui-rollback-XXXXXX")"
trap 'rm -rf "${stage_dir}"' EXIT

log_info "Extracting backup archive $(basename "${target_archive}")..."
tar -C "${stage_dir}" -xzf "${target_archive}"

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

log_info "Stopping x-ui service and sidecars..."
systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null || true
pkill -f 'mtg-linux-[^ ]* run ' 2>/dev/null || true

# 1. Restore database folder (/etc/x-ui) unless --binary-only
if [[ "${skip_db}" -eq 0 && -d "${stage_dir}/db" ]]; then
    log_info "Restoring database directory ${xui_db_folder}..."
    mkdir -p "${xui_db_folder}"
    # Remove current WAL/SHM files before restoring so stale WAL frames cannot corrupt the restored DB
    rm -f "${xui_db_folder}/x-ui.db-wal" "${xui_db_folder}/x-ui.db-shm"
    cp -a "${stage_dir}/db/." "${xui_db_folder}/"
    chmod 600 "${xui_db_folder}/x-ui.db" 2>/dev/null || true
fi

# 2. Restore main folder (/usr/local/x-ui)
if [[ -d "${stage_dir}/main" ]]; then
    log_info "Restoring application directory ${xui_folder}..."
    mkdir -p "${xui_folder}"
    rm -rf "${xui_folder:?}/"*
    cp -a "${stage_dir}/main/." "${xui_folder}/"
    chmod +x "${xui_folder}/x-ui" "${xui_folder}/x-ui.sh" 2>/dev/null || true
    chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true
    chown -R root:root "${xui_folder}" 2>/dev/null || true
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
if [[ -d "${stage_dir}/system/x-ui.service.d" ]]; then
    mkdir -p "${xui_service}/x-ui.service.d"
    cp -a "${stage_dir}/system/x-ui.service.d/." "${xui_service}/x-ui.service.d/"
fi
if [[ -f "${stage_dir}/system/x-ui.initd" ]]; then
    cp -a "${stage_dir}/system/x-ui.initd" /etc/init.d/x-ui
    chmod +x /etc/init.d/x-ui
fi

log_info "Reloading service manager and starting x-ui..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable x-ui 2>/dev/null || true
    systemctl start x-ui
    sleep 2
    if systemctl is-active --quiet x-ui; then
        log_info "Rollback succeeded! x-ui service is active and running."
    else
        log_err "x-ui service failed to start after rollback. Check: journalctl -u x-ui -n 50"
        exit 1
    fi
else
    rc-service x-ui restart
fi
