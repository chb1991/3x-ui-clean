#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Transactional Safe Upgrade Script (Mutex-Locked & Backup-Verified)
# CLEAN_SCRIPT_PROTOCOL=2
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================
set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

CLEAN_REPO="${CLEAN_REPO:-chb1991/3x-ui-clean}"

if [[ -f /etc/default/x-ui ]]; then
    # shellcheck disable=SC1091
    source /etc/default/x-ui
fi

xui_folder="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
xui_db_folder="${XUI_DB_FOLDER:-/etc/x-ui}"
xui_service="${XUI_SERVICE:-/etc/systemd/system}"
xui_log_folder="${XUI_LOG_FOLDER:-/var/log/x-ui}"
backup_root="${XUI_BACKUP_DIR:-/var/backups/x-ui}"
staging_root="${XUI_STAGING_DIR:-/var/tmp}"

# ------------------------------------------------------------------------------
# Web Panel Updater Status Contract (compatible with internal/web/service/panel/panel.go)
# ------------------------------------------------------------------------------
xui_update_run_id="${XUI_UPDATE_RUN_ID:-0}"
[[ "${xui_update_run_id}" =~ ^[0-9]+$ ]] || xui_update_run_id="0"
xui_update_status_file="${XUI_UPDATE_STATUS_FILE:-${xui_db_folder}/update-status.json}"

_write_update_status() {
    local state="$1"
    local exit_code="$2"
    local status_dir
    status_dir="$(dirname "${xui_update_status_file}")"
    mkdir -p "${status_dir}" >/dev/null 2>&1 || true
    local tmp_file="${xui_update_status_file}.tmp.$$"
    printf '{"runId":"%s","state":"%s","exitCode":%s,"finishedAt":%s}\n' \
        "${xui_update_run_id}" "${state}" "${exit_code}" "$(date +%s)" > "${tmp_file}" 2>/dev/null || true
    mv -f "${tmp_file}" "${xui_update_status_file}" >/dev/null 2>&1 || true
}

stage_dir=""
bkp_stage=""
pre_upgrade_backup=""
rollback_needed=0
service_stopped_by_us=0
existing_port=""

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
    # Never copy or replace a live SQLite database if stopping systemd failed.
    systemctl stop x-ui >/dev/null 2>&1 || {
        echo "[ERROR] Failed to stop x-ui.service" >&2
        return 1
    }
    local i
    for i in {1..20}; do
        if ! _is_xui_running; then return 0; fi
        sleep 1
    done
    echo "[ERROR] x-ui process remains alive after systemctl stop" >&2
    return 1
}

# Identify the Xray binary owned by this panel, not a different Xray service.
_panel_xray_alive() {
    local entry exe
    for entry in /proc/[0-9]*/exe; do
        [[ -e "${entry}" ]] || continue
        exe="$(readlink -f "${entry}" 2>/dev/null || true)"
        case "${exe}" in
            "${xui_folder}/bin/xray-linux-"*|"${xui_folder}/bin/xray") return 0 ;;
        esac
    done
    return 1
}

_trigger_auto_rollback() {
    local helper="${stage_dir}/helper-scripts/rollback.sh"
    [[ -n "${pre_upgrade_backup}" && -s "${pre_upgrade_backup}" &&
       -f "${pre_upgrade_backup}.sha256" && -f "${helper}" ]] || {
        echo "[CRITICAL] Rollback preconditions failed: missing archive, checksum or pinned script" >&2
        return 1
    }
    grep -q '^# CLEAN_SCRIPT_PROTOCOL=2$' "${helper}" || {
        echo "[CRITICAL] Refusing obsolete rollback helper" >&2
        return 1
    }
    echo "[AUTO-ROLLBACK] Running verified tagged rollback helper" >&2
    bash "${helper}" --auto "${pre_upgrade_backup}" --no-lock
}

_report_update_exit() {
    local code=$?
    trap - EXIT
    set +e
    if (( code != 0 )); then
        if (( rollback_needed == 1 )); then
            if _trigger_auto_rollback; then
                _write_update_status "failed" "${code}"
            else
                echo "[CRITICAL] Automatic rollback failed; use the independently verified manual backup" >&2
                _write_update_status "failed" "${code}"
            fi
        else
            if (( service_stopped_by_us == 1 )); then
                systemctl start x-ui || echo "[CRITICAL] Could not restart original service after aborted backup" >&2
            fi
            _write_update_status "failed" "${code}"
        fi
    else
        _write_update_status "success" 0
    fi
    [[ -n "${stage_dir}" && -d "${stage_dir}" ]] && rm -rf -- "${stage_dir}"
    [[ -n "${bkp_stage}" && -d "${bkp_stage}" ]] && rm -rf -- "${bkp_stage}"
    return 0
}

trap _report_update_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

_fail() {
    echo -e "${red}$1${plain}" >&2
    exit 2
}

[[ "${EUID}" -ne 0 ]] && _fail "FATAL ERROR: Please run this script with root privilege."

# ------------------------------------------------------------------------------
# Parse CLI Arguments
# ------------------------------------------------------------------------------
offline_archive=""
target_tag="${XUI_UPDATE_TAG:-}"
assume_yes=0
no_lock=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline)
            offline_archive="${2:-}"
            shift 2
            ;;
        --tag)
            target_tag="${2:-}"
            shift 2
            ;;
        --yes|-y)
            assume_yes=1
            shift
            ;;
        --no-lock)
            no_lock=1
            shift
            ;;
        v*.*.*|dev-latest)
            target_tag="$1"
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS] [vX.Y.Z]

Options:
  --offline <path>   Upgrade from a local archive (x-ui-linux-<arch>.tar.gz or offline bundle)
  --tag <vX.Y.Z>     Upgrade to a specific release tag (default: latest stable release)
  --yes, -y          Skip interactive confirmation prompt
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Process Mutex Lock (prevents concurrent update/backup/rollback execution)
# ------------------------------------------------------------------------------
if [[ "${no_lock}" -eq 0 ]]; then
    LOCK_DIR="/run/lock"
    [[ -d "${LOCK_DIR}" ]] || LOCK_DIR="/tmp"
    LOCK_FILE="${LOCK_DIR}/x-ui-clean-ops.lock"
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        _fail "ERROR: Another 3X-UI install/update/backup/rollback operation is already running (lock: ${LOCK_FILE})."
    fi
fi

# Auto-confirm when triggered by Web Panel updater or non-interactive pipe
if [[ "${xui_update_run_id}" != "0" || "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    assume_yes=1
fi

# ------------------------------------------------------------------------------
# Detect OS and CPU Architecture
# ------------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
    release="$(awk -F'[= "]' '/^ID=/{print $2}' /etc/os-release | head -n1)"
elif [[ -f /usr/lib/os-release ]]; then
    release="$(awk -F'[= "]' '/^ID=/{print $2}' /usr/lib/os-release | head -n1)"
else
    _fail "Failed to detect Linux distribution."
fi

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo 'unknown' ;;
    esac
}

TARGET_ARCH="$(arch)"
[[ "${TARGET_ARCH}" == "unknown" ]] && _fail "Unsupported CPU architecture: $(uname -m)"

if [[ ! -d "${xui_folder}" || ! -f "${xui_folder}/x-ui" ]]; then
    _fail "ERROR: 3X-UI is not installed in ${xui_folder}. Run install.sh first."
fi

if [[ "${assume_yes}" -eq 0 ]]; then
    read -rp "This will upgrade 3X-UI to the Clean (Ad-Free) edition while preserving all database & node settings. Continue? [Y/n]: " yn
    if [[ -n "${yn}" && ! "${yn}" =~ ^[Yy]$ ]]; then
        echo -e "${yellow}Upgrade cancelled.${plain}"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Step 1: Pre-Stage & Validate New Release Archive (Before Stopping Service!)
# ------------------------------------------------------------------------------
install -d -m 700 "${staging_root}"
free_kib="$(df -Pk "${staging_root}" | awk 'NR == 2 {print $4}')"
[[ "${free_kib}" =~ ^[0-9]+$ && "${free_kib}" -ge 786432 ]] || _fail "ERROR: Need at least 768 MiB free space under ${staging_root}; /tmp is tmpfs on small VPS."
stage_dir="$(mktemp -d "${staging_root}/x-ui-update-stage-XXXXXX")"
archive_file="${stage_dir}/x-ui-linux-${TARGET_ARCH}.tar.gz"
bundled_scripts_dir=""

if [[ -n "${offline_archive}" ]]; then
    [[ ! -f "${offline_archive}" ]] && _fail "ERROR: Offline archive not found: ${offline_archive}"
    offline_abs="$(readlink -f "${offline_archive}")"
    echo -e "${green}[1/6] Validating offline archive: ${offline_abs}${plain}"
    [[ -f "${offline_abs}.sha256" ]] || _fail "ERROR: Missing offline .sha256 sidecar; verify the Release checksum before upgrading."
    (cd "$(dirname "${offline_abs}")" && sha256sum -c "$(basename "${offline_abs}.sha256")") || _fail "ERROR: Offline archive SHA256 mismatch!"
    tar -C "${stage_dir}" -xzf "${offline_abs}" || _fail "ERROR: Failed to extract offline archive."
    if [[ ! -f "${stage_dir}/x-ui/x-ui" ]]; then
        inner_tar="$(find "${stage_dir}" -type f -name "x-ui-linux-${TARGET_ARCH}.tar.gz" | head -n1 || true)"
        [[ -z "${inner_tar}" ]] && _fail "ERROR: Offline archive does not contain x-ui/ or x-ui-linux-${TARGET_ARCH}.tar.gz"
        [[ -f "${inner_tar}.sha256" ]] || _fail "ERROR: Missing inner archive .sha256"
        (cd "$(dirname "${inner_tar}")" && sha256sum -c "$(basename "${inner_tar}.sha256")") || _fail "ERROR: Inner archive SHA256 mismatch!"
        tar -C "${stage_dir}" -xzf "${inner_tar}" || _fail "ERROR: Failed to extract inner x-ui archive."
    fi
    bundled_scripts_dir="$(find "${stage_dir}" -maxdepth 2 -type d -name "scripts" | head -n1 || true)"
else
    command -v curl >/dev/null 2>&1 || _fail "ERROR: 'curl' is required for online upgrades."
    if [[ -z "${target_tag}" ]]; then
        echo -e "${green}[1/6] Resolving latest release tag from ${CLEAN_REPO}...${plain}"
        target_tag="$(curl -fsSL --retry 3 --connect-timeout 15 "https://api.github.com/repos/${CLEAN_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)"
        if [[ -z "${target_tag}" ]]; then
            redirect_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 "https://github.com/${CLEAN_REPO}/releases/latest" 2>/dev/null || true)"
            target_tag="$(echo "${redirect_url}" | sed -n 's#.*/releases/tag/##p' | tr -d '[:space:]')"
        fi
        [[ -z "${target_tag}" ]] && _fail "ERROR: Could not resolve latest release tag from ${CLEAN_REPO}."
    fi

    # Download the fully versioned bundle containing the exact matching helper
    # scripts. The upstream numeric Git tag may refer to an older commit; do not
    # fetch rollback logic from the tag's raw source tree.
    archive_file="${stage_dir}/3x-ui-clean-${target_tag}-linux-${TARGET_ARCH}-offline.tar.gz"
    download_url="https://github.com/${CLEAN_REPO}/releases/download/${target_tag}/$(basename "${archive_file}")"
    sha_url="${download_url}.sha256"
    echo -e "${green}[1/6] Downloading 3X-UI Clean ${target_tag} (${TARGET_ARCH})...${plain}"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 -o "${archive_file}" "${download_url}" || _fail "ERROR: Failed to download ${download_url}"

    # Verify SHA256 (mandatory for all tagged releases that publish .sha256)
    echo -e "${green}Verifying SHA256 checksum...${plain}"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${archive_file}.sha256" "${sha_url}"; then
        _fail "ERROR: Failed to download SHA256 checksum file from ${sha_url}"
    fi
    expected_sha="$(awk '{print $1}' "${archive_file}.sha256" | tr 'A-F' 'a-f')"
    actual_sha="$(sha256sum "${archive_file}" | awk '{print $1}' | tr 'A-F' 'a-f')"
    if [[ -z "${expected_sha}" || "${expected_sha}" != "${actual_sha}" ]]; then
        _fail "ERROR: SHA256 mismatch! Expected ${expected_sha}, got ${actual_sha}"
    fi

    tar -C "${stage_dir}" -xzf "${archive_file}" || _fail "ERROR: Failed to extract downloaded offline bundle."
    inner_tar="$(find "${stage_dir}" -maxdepth 3 -type f -name "x-ui-linux-${TARGET_ARCH}.tar.gz" | head -n1 || true)"
    [[ -n "${inner_tar}" && -f "${inner_tar}.sha256" ]] ||
        _fail "ERROR: Downloaded bundle missing inner application archive and matching checksum"
    (cd "$(dirname "${inner_tar}")" && sha256sum -c "$(basename "${inner_tar}.sha256")") ||
        _fail "ERROR: Inner application checksum failed"
    tar -C "${stage_dir}" -xzf "${inner_tar}" || _fail "ERROR: Failed to extract application archive"
    bundled_scripts_dir="$(find "${stage_dir}" -maxdepth 2 -type d -name scripts | head -n1 || true)"
fi

[[ ! -s "${stage_dir}/x-ui/x-ui" ]] && _fail "ERROR: Staged archive is missing x-ui binary."
chmod +x "${stage_dir}/x-ui/x-ui"

if [[ "${TARGET_ARCH}" == "armv5" || "${TARGET_ARCH}" == "armv6" || "${TARGET_ARCH}" == "armv7" ]]; then
    mv -f "${stage_dir}/x-ui/bin/xray-linux-${TARGET_ARCH}" "${stage_dir}/x-ui/bin/xray-linux-arm32" 2>/dev/null || true
    chmod +x "${stage_dir}/x-ui/bin/xray-linux-arm32" 2>/dev/null || true
    if [[ -f "${stage_dir}/x-ui/bin/mtg-linux-${TARGET_ARCH}" ]]; then
        mv -f "${stage_dir}/x-ui/bin/mtg-linux-${TARGET_ARCH}" "${stage_dir}/x-ui/bin/mtg-linux-arm" 2>/dev/null || true
        chmod +x "${stage_dir}/x-ui/bin/mtg-linux-arm" 2>/dev/null || true
    fi
else
    chmod +x "${stage_dir}/x-ui/bin/xray-linux-${TARGET_ARCH}" 2>/dev/null || true
    chmod +x "${stage_dir}/x-ui/bin/mtg-linux-${TARGET_ARCH}" 2>/dev/null || true
fi

new_ver="$("${stage_dir}/x-ui/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
[[ -z "${new_ver}" ]] && _fail "ERROR: Staged x-ui binary failed execution check ('x-ui -v'). Aborting before stopping service."
echo -e "${green}Staged binary verified: v${new_ver}${plain}"

# Pre-fetch helper scripts into staging while service is still running (minimizes downtime)
mkdir -p "${stage_dir}/helper-scripts"
if [[ -n "${bundled_scripts_dir}" && -d "${bundled_scripts_dir}" ]]; then
    cp -f "${bundled_scripts_dir}/"*.sh "${stage_dir}/helper-scripts/" 2>/dev/null || true

fi

# Refuse known-vulnerable helper bundles before touching the live service.
[[ -s "${stage_dir}/helper-scripts/rollback.sh" ]] || _fail "ERROR: Missing rollback helper in release bundle"
grep -q '^# CLEAN_SCRIPT_PROTOCOL=2$' "${stage_dir}/helper-scripts/rollback.sh" ||
    _fail "ERROR: Outdated release bundle; rebuild a release with the reviewed maintenance scripts."
# Step 2: Stop Service (Verified) & Create Verified Pre-Upgrade Backup
# ------------------------------------------------------------------------------
echo -e "${green}[2/6] Staging backup, stopping x-ui, and verifying SQLite snapshot...${plain}"
had_xray_before=0
_panel_xray_alive && had_xray_before=1
old_ver="$("${xui_folder}/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
[[ -n "${old_ver}" ]] || old_ver="unknown"

pre_settings="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
existing_port="$(echo "${pre_settings}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"
existing_webBasePath="$(echo "${pre_settings}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -n1 || true)"
pre_port="${existing_port}"
pre_webBasePath="${existing_webBasePath}"
pre_listenIP="$(echo "${pre_settings}" | grep -Eo 'listenIP: .+' | awk '{print $2}' | head -n1 || true)"
[[ "${pre_port}" =~ ^[0-9]+$ && "${pre_port}" -ge 1 && "${pre_port}" -le 65535 ]] ||
    _fail "ERROR: Could not read original listening port; refusing in-place upgrade"
[[ -s "${xui_db_folder}/x-ui.db" ]] || _fail "ERROR: Existing SQLite database missing or empty"

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"
ts="$(date +%Y%m%d-%H%M%S)"
pre_upgrade_backup="${backup_root}/x-ui-backup-${ts}-v${old_ver}-pre-upgrade.tar.gz"
bkp_stage="$(mktemp -d "${backup_root}/.bkp-stage-${ts}-XXXXXX")"
mkdir -p "${bkp_stage}/db" "${bkp_stage}/main" "${bkp_stage}/system"

# Stage static binaries and service units BEFORE stopping x-ui to minimize Xray downtime
[[ -d "${xui_folder}" ]] && cp -a "${xui_folder}/." "${bkp_stage}/main/"
[[ -f /usr/bin/x-ui ]] && cp -a /usr/bin/x-ui "${bkp_stage}/system/x-ui-bin"
[[ -f /etc/default/x-ui ]] && cp -a /etc/default/x-ui "${bkp_stage}/system/default-x-ui"
[[ -f "${xui_service}/x-ui.service" ]] && cp -a "${xui_service}/x-ui.service" "${bkp_stage}/system/x-ui.service"
if [[ -d "${xui_service}/x-ui.service.d" ]]; then
    mkdir -p "${bkp_stage}/system/x-ui.service.d"
    cp -a "${xui_service}/x-ui.service.d/." "${bkp_stage}/system/x-ui.service.d/"
fi

# Now stop x-ui and strictly verify it is no longer running
service_stopped_by_us=1
if ! _stop_xui_and_verify; then
    _fail "ERROR: Failed to stop x-ui service cleanly within 15s! Refusing to proceed while process is active."
fi

# Re-capture Xray's runtime config after the old panel has stopped.
if [[ -f "${xui_folder}/bin/config.json" ]]; then
    cp -a "${xui_folder}/bin/config.json" "${bkp_stage}/main/bin/config.json"
fi
# Copy the SQLite database and its matching WAL/SHM after all known writers stop.
# Copy database folder now that x-ui is stopped and WAL is flushed
if [[ -d "${xui_db_folder}" ]]; then
    cp -a "${xui_db_folder}/." "${bkp_stage}/db/"
fi

db_sha256=""
if [[ -f "${xui_db_folder}/x-ui.db" ]]; then
    src_db_sha="$(sha256sum "${xui_db_folder}/x-ui.db" | awk '{print $1}')"
    staged_db_sha="$(sha256sum "${bkp_stage}/db/x-ui.db" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -z "${src_db_sha}" || "${src_db_sha}" != "${staged_db_sha}" ]]; then
        systemctl start x-ui >/dev/null 2>&1 || rc-service x-ui start >/dev/null 2>&1 || true
        _fail "CRITICAL: Staged database SHA256 mismatch! Original service restarted; upgrade aborted."
    fi
    db_sha256="${src_db_sha}"
fi

bin_sha256=""
[[ -f "${bkp_stage}/main/x-ui" ]] && bin_sha256="$(sha256sum "${bkp_stage}/main/x-ui" | awk '{print $1}')"

cat > "${bkp_stage}/backup-meta.env" <<EOF
BACKUP_TIMESTAMP="${ts}"
BACKUP_CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP_TAG="pre-upgrade"
PANEL_VERSION="${old_ver}"
PANEL_PORT="${existing_port}"
PANEL_WEB_BASE_PATH="${existing_webBasePath}"
XUI_MAIN_FOLDER="${xui_folder}"
XUI_DB_FOLDER="${xui_db_folder}"
XUI_SERVICE="${xui_service}"
DB_SHA256="${db_sha256}"
BIN_SHA256="${bin_sha256}"
EOF

# Create compressed backup archive and strictly verify before modifying live installation
if ! tar -C "${bkp_stage}" -czf "${pre_upgrade_backup}" .; then
    rm -f "${pre_upgrade_backup}"
    systemctl start x-ui >/dev/null 2>&1 || rc-service x-ui start >/dev/null 2>&1 || true
    _fail "CRITICAL: Failed to create pre-upgrade tar archive (check disk space in ${backup_root})! Original service restarted; upgrade aborted."
fi

rm -rf "${bkp_stage}"
bkp_stage=""

tar_listing="$(tar -tzf "${pre_upgrade_backup}" 2>/dev/null || true)"
if [[ ! -s "${pre_upgrade_backup}" || -z "${tar_listing}" ]]; then
    rm -f "${pre_upgrade_backup}"
    systemctl start x-ui >/dev/null 2>&1 || rc-service x-ui start >/dev/null 2>&1 || true
    _fail "CRITICAL: Pre-upgrade backup archive failed tar -tzf integrity check! Original service restarted; upgrade aborted."
fi

if [[ -f "${xui_db_folder}/x-ui.db" ]] && ! echo "${tar_listing}" | grep -qE '^\./db/x-ui\.db$'; then
    rm -f "${pre_upgrade_backup}"
    systemctl start x-ui >/dev/null 2>&1 || rc-service x-ui start >/dev/null 2>&1 || true
    _fail "CRITICAL: Pre-upgrade backup archive is missing ./db/x-ui.db! Original service restarted; upgrade aborted."
fi

chmod 600 "${pre_upgrade_backup}"
(cd "${backup_root}" && sha256sum "$(basename "${pre_upgrade_backup}")" > "$(basename "${pre_upgrade_backup}").sha256")
chmod 600 "${pre_upgrade_backup}.sha256"
ln -sfn "${pre_upgrade_backup}" "${backup_root}/latest.tar.gz"
ln -sfn "${pre_upgrade_backup}.sha256" "${backup_root}/latest.tar.gz.sha256"
(cd "${backup_root}" && sha256sum -c "$(basename "${pre_upgrade_backup}.sha256")" >/dev/null) ||
    _fail "CRITICAL: Failed to verify backup archive checksum"
command -v python3 >/dev/null 2>&1 || _fail "CRITICAL: python3 is required to validate WAL snapshot"
python3 - "${pre_upgrade_backup}" <<'PY'
import os, sqlite3, shutil, sys, tarfile, tempfile
with tarfile.open(sys.argv[1], 'r:gz') as ar:
    with tempfile.TemporaryDirectory(prefix='xui-db-verify-', dir='/var/tmp') as d:
        for name in ['./db/x-ui.db', './db/x-ui.db-wal', './db/x-ui.db-shm']:
            try:
                member = ar.getmember(name)
            except KeyError:
                continue
            with ar.extractfile(member) as src, open(os.path.join(d, os.path.basename(name)), 'wb') as out:
                shutil.copyfileobj(src, out)
        con = sqlite3.connect(f'file:{d}/x-ui.db?mode=ro', uri=True, timeout=15)
        try:
            value = con.execute('PRAGMA integrity_check').fetchone()[0]
            if value != 'ok':
                raise RuntimeError('SQLite integrity_check returned '+str(value))
        finally:
            con.close()
print('WAL-consistent backup integrity: OK')
PY
echo -e "${green}Verified pre-upgrade backup saved to: ${pre_upgrade_backup}${plain}"

# Backup is 100% verified on disk — arm auto-rollback for Steps 3..6
rollback_needed=1

# ------------------------------------------------------------------------------
# Step 3: Replace Application Binaries (Preserving /etc/x-ui/x-ui.db & bin/config.json)
# ------------------------------------------------------------------------------
echo -e "${green}[3/6] Installing new 3X-UI Clean binaries into ${xui_folder}...${plain}"
mkdir -p "${xui_folder}/bin" "${xui_folder}/scripts" "${xui_log_folder}"

cp -f "${stage_dir}/x-ui/x-ui" "${xui_folder}/x-ui"
chmod +x "${xui_folder}/x-ui"

if [[ -f "${stage_dir}/x-ui/x-ui.sh" ]]; then
    cp -f "${stage_dir}/x-ui/x-ui.sh" "${xui_folder}/x-ui.sh"
    cp -f "${stage_dir}/x-ui/x-ui.sh" /usr/bin/x-ui
    chmod +x "${xui_folder}/x-ui.sh" /usr/bin/x-ui
fi

for item in "${stage_dir}/x-ui/bin/"*; do
    [[ -e "${item}" ]] || continue
    item_name="$(basename "${item}")"
    # Never replace the generated Xray configuration, even on explicit runtime upgrade.
    [[ "${item_name}" == "config.json" ]] && continue
    # This is a clean panel-only upgrade. Preserve working Xray/MTG/geo data
    # unless the operator explicitly opts into upgrading bundled runtime dependencies.
    if [[ -e "${xui_folder}/bin/${item_name}" &&
          "${XUI_UPGRADE_RUNTIME_DEPS:-0}" != "1" ]]; then
        continue
    fi
    cp -rf "${item}" "${xui_folder}/bin/"
done
chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true

if compgen -G "${stage_dir}/helper-scripts/*.sh" >/dev/null 2>&1; then
    cp -f "${stage_dir}/helper-scripts/"*.sh "${xui_folder}/scripts/"
    chmod +x "${xui_folder}/scripts/"*.sh
fi

chown -R root:root "${xui_folder}" 2>/dev/null || true
[[ -f "${xui_folder}/bin/config.json" ]] && chmod 640 "${xui_folder}/bin/config.json" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Step 4: Run Idempotent Database Migration
# ------------------------------------------------------------------------------
echo -e "${green}[4/6] Running database schema migration check ('x-ui migrate')...${plain}"
"${xui_folder}/x-ui" migrate || _fail "ERROR: 'x-ui migrate' failed!"

settings_out="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
[[ -z "${settings_out}" ]] && _fail "ERROR: Failed to read panel settings after migration!"
existing_port="$(echo "${settings_out}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"
existing_webBasePath="$(echo "${settings_out}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -n1 || true)"
post_listenIP="$(echo "${settings_out}" | grep -Eo 'listenIP: .+' | awk '{print $2}' | head -n1 || true)"
[[ "${existing_port}" == "${pre_port}" &&
   "${existing_webBasePath}" == "${pre_webBasePath}" &&
   "${post_listenIP}" == "${pre_listenIP}" ]] ||
    _fail "ERROR: port, webBasePath, or listenIP changed during migration; refusing to commit"

# ------------------------------------------------------------------------------
# Step 5: Refresh Service Unit & Sandbox Drop-In
# ------------------------------------------------------------------------------
echo -e "${green}[5/6] Updating service unit configuration...${plain}"
if [[ "${release}" == "alpine" ]]; then
    if [[ -f "${stage_dir}/x-ui/x-ui.rc" ]]; then
        cp -f "${stage_dir}/x-ui/x-ui.rc" /etc/init.d/x-ui
        chmod +x /etc/init.d/x-ui
    fi
    rc-update add x-ui default >/dev/null 2>&1 || true
    rc-service x-ui restart || _fail "ERROR: Failed to start x-ui via OpenRC."
else
    unit_src="${stage_dir}/x-ui/x-ui.service.debian"
    case "${release}" in
        arch | manjaro | parch)
            [[ -f "${stage_dir}/x-ui/x-ui.service.arch" ]] && unit_src="${stage_dir}/x-ui/x-ui.service.arch"
            ;;
        centos | rhel | almalinux | rocky | ol | fedora | amzn)
            [[ -f "${stage_dir}/x-ui/x-ui.service.rhel" ]] && unit_src="${stage_dir}/x-ui/x-ui.service.rhel"
            ;;
    esac
    # Pure ad-removal upgrade: preserve the production unit and all local
    # sandbox/Cloudflare-related drop-ins. Opt in only when explicitly requested.
    if [[ "${XUI_REPLACE_SYSTEMD:-0}" == "1" ]]; then
        [[ -f "${unit_src}" ]] || _fail "ERROR: Requested systemd replacement but packaged unit is absent"
        cp -f "${unit_src}" "${xui_service}/x-ui.service"
    fi
    # Default: do not rewrite 10-xui-sandbox.conf (or any administrator override).
    systemctl daemon-reload
    systemctl start x-ui || _fail "ERROR: systemctl start x-ui failed!"
fi

# ------------------------------------------------------------------------------
# Step 6: Post-Start Health Check (Service Active + Port Listening)
# ------------------------------------------------------------------------------
echo -e "${green}[6/6] Running post-upgrade health checks...${plain}"
healthy=0
command -v ss >/dev/null 2>&1 || _fail "ERROR: ss from iproute2 is required for health check"
for _ in {1..15}; do
    sleep 2
    systemctl is-active --quiet x-ui || continue
    if [[ -n "${pre_listenIP}" ]]; then
        expected_socket="${pre_listenIP}:${existing_port}"
        if ss -H -ltn | awk -v expected="${expected_socket}" '$4 == expected {found=1} END {exit !found}'; then
            healthy=1
            break
        fi
    else
        if ss -H -ltn | awk -v port=":${existing_port}" 'index($4,port)==length($4)-length(port)+1 {found=1} END {exit !found}'; then
            healthy=1
            break
        fi
    fi
done

if [[ "${healthy}" -ne 1 ]]; then
    _fail "ERROR: Post-upgrade health check failed (x-ui is not active or port ${existing_port} is not listening)."
fi
if (( had_xray_before == 1 )) && ! _panel_xray_alive; then
    _fail "ERROR: Panel-managed Xray ran before the upgrade but did not restart."
fi

# Health check passed — disarm auto-rollback trap
rollback_needed=0
service_stopped_by_us=0

echo ""
echo -e "${green}═══════════════════════════════════════════════════════════════${plain}"
echo -e "${green}  3X-UI Clean v${new_ver} Upgrade Successful! (Zero Ads)       ${plain}"
echo -e "${green}═══════════════════════════════════════════════════════════════${plain}"
echo -e "${green}  Database Path : ${xui_db_folder}/x-ui.db (Preserved)${plain}"
echo -e "${green}  Panel Port    : ${existing_port:-unchanged} (Preserved)${plain}"
echo -e "${green}  WebBasePath   : ${existing_webBasePath:-unchanged} (Preserved)${plain}"
echo -e "${green}  Backup Saved  : ${pre_upgrade_backup}${plain}"
echo -e "${green}  Rollback Cmd  : x-ui rollback --latest${plain}"
echo -e "${green}═══════════════════════════════════════════════════════════════${plain}"
