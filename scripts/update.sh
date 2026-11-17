#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Transactional Safe Upgrade Script (Online & Offline + Auto-Rollback)
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================

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
    mkdir -p "${status_dir}" >/dev/null 2>&1
    local tmp_file="${xui_update_status_file}.tmp.$$"
    printf '{"runId":"%s","state":"%s","exitCode":%s,"finishedAt":%s}\n' \
        "${xui_update_run_id}" "${state}" "${exit_code}" "$(date +%s)" > "${tmp_file}" 2>/dev/null
    mv -f "${tmp_file}" "${xui_update_status_file}" >/dev/null 2>&1
}

stage_dir=""
pre_upgrade_backup=""
rollback_needed=0

_trigger_auto_rollback() {
    if [[ -z "${pre_upgrade_backup}" || ! -f "${pre_upgrade_backup}" ]]; then
        echo -e "${red}[AUTO-ROLLBACK] No pre-upgrade backup archive available to restore.${plain}" >&2
        return 1
    fi
    echo -e "${yellow}[AUTO-ROLLBACK] Upgrade failed! Restoring pre-upgrade snapshot: ${pre_upgrade_backup}${plain}" >&2
    systemctl stop x-ui >/dev/null 2>&1 || rc-service x-ui stop >/dev/null 2>&1 || true
    local rb_stage
    rb_stage="$(mktemp -d "/tmp/x-ui-autorollback-XXXXXX")"
    if tar -C "${rb_stage}" -xzf "${pre_upgrade_backup}" 2>/dev/null; then
        if [[ -d "${rb_stage}/db" ]]; then
            rm -f "${xui_db_folder}/x-ui.db-wal" "${xui_db_folder}/x-ui.db-shm"
            cp -a "${rb_stage}/db/." "${xui_db_folder}/"
        fi
        if [[ -d "${rb_stage}/main" ]]; then
            rm -rf "${xui_folder:?}/"*
            cp -a "${rb_stage}/main/." "${xui_folder}/"
            chmod +x "${xui_folder}/x-ui" "${xui_folder}/x-ui.sh" 2>/dev/null || true
            chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true
        fi
        if [[ -f "${rb_stage}/system/x-ui-bin" ]]; then
            cp -a "${rb_stage}/system/x-ui-bin" /usr/bin/x-ui
            chmod +x /usr/bin/x-ui
        fi
        if [[ -f "${rb_stage}/system/x-ui.service" ]]; then
            cp -a "${rb_stage}/system/x-ui.service" "${xui_service}/x-ui.service"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start x-ui >/dev/null 2>&1 || rc-service x-ui start >/dev/null 2>&1 || true
        echo -e "${green}[AUTO-ROLLBACK] Previous version and database restored successfully.${plain}" >&2
    fi
    rm -rf "${rb_stage}"
}

_report_update_exit() {
    local code=$?
    [[ -n "${stage_dir}" && -d "${stage_dir}" ]] && rm -rf "${stage_dir}"
    if [[ "${code}" -eq 0 ]]; then
        _write_update_status "success" "0"
    else
        if [[ "${rollback_needed}" -eq 1 ]]; then
            _trigger_auto_rollback
        fi
        _write_update_status "failed" "${code}"
    fi
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
stage_dir="$(mktemp -d "/tmp/x-ui-update-stage-XXXXXX")"
archive_file="${stage_dir}/x-ui-linux-${TARGET_ARCH}.tar.gz"

if [[ -n "${offline_archive}" ]]; then
    [[ ! -f "${offline_archive}" ]] && _fail "ERROR: Offline archive not found: ${offline_archive}"
    offline_abs="$(readlink -f "${offline_archive}")"
    echo -e "${green}[1/6] Validating offline archive: ${offline_abs}${plain}"
    if [[ -f "${offline_abs}.sha256" ]]; then
        (cd "$(dirname "${offline_abs}")" && sha256sum -c "$(basename "${offline_abs}.sha256")") || _fail "ERROR: Offline archive SHA256 mismatch!"
    fi
    # Support both raw x-ui-linux-<arch>.tar.gz and outer 3x-ui-clean-*-offline.tar.gz bundle
    tar -C "${stage_dir}" -xzf "${offline_abs}" || _fail "ERROR: Failed to extract offline archive."
    if [[ -f "${stage_dir}/x-ui/x-ui" ]]; then
        : # Already extracted x-ui/ directly
    elif compgen -G "${stage_dir}/**/x-ui-linux-${TARGET_ARCH}.tar.gz" >/dev/null 2>&1; then
        inner_tar="$(find "${stage_dir}" -type f -name "x-ui-linux-${TARGET_ARCH}.tar.gz" | head -n1)"
        if [[ -f "${inner_tar}.sha256" ]]; then
            (cd "$(dirname "${inner_tar}")" && sha256sum -c "$(basename "${inner_tar}.sha256")") || _fail "ERROR: Inner archive SHA256 mismatch!"
        fi
        tar -C "${stage_dir}" -xzf "${inner_tar}" || _fail "ERROR: Failed to extract inner x-ui archive."
    else
        _fail "ERROR: Offline archive does not contain x-ui/ or x-ui-linux-${TARGET_ARCH}.tar.gz"
    fi
    # Copy bundled helper scripts if present in offline bundle
     bundled_scripts_dir="$(find "${stage_dir}" -maxdepth 2 -type d -name "scripts" | head -n1 || true)"
else
    command -v curl >/dev/null 2>&1 || _fail "ERROR: 'curl' is required for online upgrades."
    if [[ -z "${target_tag}" ]]; then
        echo -e "${green}[1/6] Resolving latest release tag from ${CLEAN_REPO}...${plain}"
        target_tag="$(curl -fsSL --retry 3 --connect-timeout 15 "https://api.github.com/repos/${CLEAN_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)"
        if [[ -z "${target_tag}" ]]; then
            # Fallback to GitHub redirect URL if API rate-limited
            redirect_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 "https://github.com/${CLEAN_REPO}/releases/latest" 2>/dev/null || true)"
            target_tag="$(echo "${redirect_url}" | sed -n 's#.*/releases/tag/##p' | tr -d '[:space:]')"
        fi
        [[ -z "${target_tag}" ]] && _fail "ERROR: Could not resolve latest release tag from ${CLEAN_REPO}."
    fi

    download_url="https://github.com/${CLEAN_REPO}/releases/download/${target_tag}/x-ui-linux-${TARGET_ARCH}.tar.gz"
    sha_url="${download_url}.sha256"
    echo -e "${green}[1/6] Downloading 3X-UI Clean ${target_tag} (${TARGET_ARCH})...${plain}"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 -o "${archive_file}" "${download_url}" || _fail "ERROR: Failed to download ${download_url}"

    if curl -fsSL --retry 3 --connect-timeout 15 -o "${archive_file}.sha256" "${sha_url}" 2>/dev/null; then
        echo -e "${green}Verifying SHA256 checksum...${plain}"
        expected_sha="$(awk '{print $1}' "${archive_file}.sha256" | tr 'A-F' 'a-f')"
        actual_sha="$(sha256sum "${archive_file}" | awk '{print $1}' | tr 'A-F' 'a-f')"
        if [[ -z "${expected_sha}" || "${expected_sha}" != "${actual_sha}" ]]; then
            _fail "ERROR: SHA256 mismatch! Expected ${expected_sha}, got ${actual_sha}"
        fi
    fi

    tar -C "${stage_dir}" -xzf "${archive_file}" || _fail "ERROR: Failed to extract downloaded archive."
fi

# Verify staged files before touching the live installation
[[ ! -s "${stage_dir}/x-ui/x-ui" ]] && _fail "ERROR: Staged archive is missing x-ui binary."
chmod +x "${stage_dir}/x-ui/x-ui"

# Normalize arm32 binary names inside staging
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

# Smoke-test staged binary on current CPU/kernel before stopping service
new_ver="$("${stage_dir}/x-ui/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
[[ -z "${new_ver}" ]] && _fail "ERROR: Staged x-ui binary failed execution check ('x-ui -v'). Aborting before stopping service."
echo -e "${green}Staged binary verified: v${new_ver}${plain}"

# ------------------------------------------------------------------------------
# Step 2: Stop Service & Create Full Consistent Pre-Upgrade Backup
# ------------------------------------------------------------------------------
echo -e "${green}[2/6] Stopping x-ui and creating full pre-upgrade backup...${plain}"
old_ver="$("${xui_folder}/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || echo 'unknown')"

systemctl stop x-ui >/dev/null 2>&1 || rc-service x-ui stop >/dev/null 2>&1 || true
pkill -f 'mtg-linux-[^ ]* run ' >/dev/null 2>&1 || true

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"
ts="$(date +%Y%m%d-%H%M%S)"
pre_upgrade_backup="${backup_root}/x-ui-backup-${ts}-v${old_ver}-pre-upgrade.tar.gz"
bkp_stage="$(mktemp -d "${backup_root}/.bkp-stage-${ts}-XXXXXX")"
mkdir -p "${bkp_stage}/db" "${bkp_stage}/main" "${bkp_stage}/system"

[[ -d "${xui_db_folder}" ]] && cp -a "${xui_db_folder}/." "${bkp_stage}/db/"
[[ -d "${xui_folder}" ]] && cp -a "${xui_folder}/." "${bkp_stage}/main/"
[[ -f /usr/bin/x-ui ]] && cp -a /usr/bin/x-ui "${bkp_stage}/system/x-ui-bin"
[[ -f /etc/default/x-ui ]] && cp -a /etc/default/x-ui "${bkp_stage}/system/default-x-ui"
[[ -f "${xui_service}/x-ui.service" ]] && cp -a "${xui_service}/x-ui.service" "${bkp_stage}/system/x-ui.service"
if [[ -d "${xui_service}/x-ui.service.d" ]]; then
    mkdir -p "${bkp_stage}/system/x-ui.service.d"
    cp -a "${xui_service}/x-ui.service.d/." "${bkp_stage}/system/x-ui.service.d/"
fi

cat > "${bkp_stage}/backup-meta.env" <<EOF
BACKUP_TIMESTAMP="${ts}"
BACKUP_CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP_TAG="pre-upgrade"
PANEL_VERSION="${old_ver}"
XUI_MAIN_FOLDER="${xui_folder}"
XUI_DB_FOLDER="${xui_db_folder}"
XUI_SERVICE="${xui_service}"
EOF

tar -C "${bkp_stage}" -czf "${pre_upgrade_backup}" .
rm -rf "${bkp_stage}"
chmod 600 "${pre_upgrade_backup}"
(cd "${backup_root}" && sha256sum "$(basename "${pre_upgrade_backup}")" > "$(basename "${pre_upgrade_backup}").sha256")
ln -sfn "${pre_upgrade_backup}" "${backup_root}/latest.tar.gz"
ln -sfn "${pre_upgrade_backup}.sha256" "${backup_root}/latest.tar.gz.sha256"
echo -e "${green}Pre-upgrade backup saved to: ${pre_upgrade_backup}${plain}"

# From this point on, any failure automatically triggers _trigger_auto_rollback
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
    cp -rf "${item}" "${xui_folder}/bin/"
done
chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true

# Install helper scripts (backup.sh, rollback.sh, update.sh) into /usr/local/x-ui/scripts/
if [[ -n "${bundled_scripts_dir:-}" && -d "${bundled_scripts_dir}" ]]; then
    cp -f "${bundled_scripts_dir}/"*.sh "${xui_folder}/scripts/" 2>/dev/null || true
    chmod +x "${xui_folder}/scripts/"*.sh 2>/dev/null || true
elif [[ -z "${offline_archive}" ]]; then
    for sname in backup.sh rollback.sh update.sh install.sh; do
        curl -fsSL --retry 3 --connect-timeout 10 \
            "https://raw.githubusercontent.com/${CLEAN_REPO}/main/scripts/${sname}" \
            -o "${xui_folder}/scripts/${sname}" 2>/dev/null && chmod +x "${xui_folder}/scripts/${sname}" || true
    done
fi

chown -R root:root "${xui_folder}" 2>/dev/null || true
[[ -f "${xui_folder}/bin/config.json" ]] && chmod 640 "${xui_folder}/bin/config.json" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Step 4: Run Idempotent Database Migration
# ------------------------------------------------------------------------------
echo -e "${green}[4/6] Running database schema migration check ('x-ui migrate')...${plain}"
"${xui_folder}/x-ui" migrate || _fail "ERROR: 'x-ui migrate' failed!"

# Verify existing settings (NEVER overwrite existing custom webBasePath, port, or listenIP!)
settings_out="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
existing_port="$(echo "${settings_out}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"
existing_webBasePath="$(echo "${settings_out}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -n1 || true)"

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
    if [[ -f "${unit_src}" ]]; then
        cp -f "${unit_src}" "${xui_service}/x-ui.service"
    fi
    # Ensure sandbox drop-in grants write access to custom folders and backup dir
    dropin_dir="${xui_service}/x-ui.service.d"
    mkdir -p "${dropin_dir}"
    sys_ver="$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}' | tr -cd '0-9')"
    {
        echo "[Service]"
        echo "ReadWritePaths=-${xui_db_folder} -${xui_folder} -${xui_log_folder} -${backup_root}"
        echo "ReadWriteDirectories=-${xui_db_folder} -${xui_folder} -${xui_log_folder} -${backup_root}"
        if [[ -n "${sys_ver}" && "${sys_ver}" -ge 239 ]]; then
            echo "SystemCallFilter=@system-service"
            echo "SystemCallErrorNumber=EPERM"
        fi
    } > "${dropin_dir}/10-xui-sandbox.conf"

    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl start x-ui || _fail "ERROR: systemctl start x-ui failed!"
fi

# ------------------------------------------------------------------------------
# Step 6: Post-Start Health Check (Service Active + Port Listening)
# ------------------------------------------------------------------------------
echo -e "${green}[6/6] Running post-upgrade health checks...${plain}"
healthy=0
for _ in 1 2 3 4 5; do
    sleep 2
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet x-ui; then
            continue
        fi
    fi
    if [[ -n "${existing_port}" ]] && command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -qE ":${existing_port}\\b"; then
            healthy=1
            break
        fi
    else
        healthy=1
        break
    fi
done

if [[ "${healthy}" -ne 1 ]]; then
    _fail "ERROR: Post-upgrade health check failed (x-ui is not active or port ${existing_port} is not listening)."
fi

# Health check passed — disable auto-rollback trap
rollback_needed=0

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
