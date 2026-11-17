#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Unified Online & Offline Installer (Existing-DB Safe)
# CLEAN_SCRIPT_PROTOCOL=2
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================
set -euo pipefail

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

offline_archive=""
target_tag=""
force_fresh=0
assume_yes=0

orig_args=("$@")
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
        --force-fresh)
            force_fresh=1
            shift
            ;;
        --yes|-y)
            assume_yes=1
            shift
            ;;
        v*.*.*)
            target_tag="$1"
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS] [vX.Y.Z]

Options:
  --offline <path>   Install or upgrade from a local archive without internet access
  --tag <vX.Y.Z>     Install a specific release tag (default: latest stable release)
  --yes, -y          Non-interactive mode (accept defaults)
  --force-fresh      Force fresh credential/port initialization even if x-ui is installed
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

_fail() {
    echo -e "${red}$1${plain}" >&2
    exit 1
}

[[ "${EUID}" -ne 0 ]] && _fail "FATAL ERROR: Please run this script with root privilege."

# ------------------------------------------------------------------------------
# Safeguard: If an existing installation & SQLite database are present, delegate
# to transactional update.sh so port, listenIP, webBasePath, and nodes stay intact!
# ------------------------------------------------------------------------------
if [[ -f "${xui_db_folder}/x-ui.db" && -f "${xui_folder}/x-ui" && "${force_fresh}" -eq 0 ]]; then
    echo -e "${yellow}═══════════════════════════════════════════════════════════════${plain}"
    echo -e "${yellow}  Existing 3X-UI installation detected (${xui_db_folder}/x-ui.db)${plain}"
    echo -e "${yellow}  Switching to Safe In-Place Upgrade Mode to preserve all      ${plain}"
    echo -e "${yellow}  nodes, VLESS/REALITY keys, port, listenIP, and webBasePath!  ${plain}"
    echo -e "${yellow}═══════════════════════════════════════════════════════════════${plain}"
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
    if [[ -f "${script_dir}/update.sh" ]]; then
        exec bash "${script_dir}/update.sh" "${orig_args[@]}"
    fi
    if [[ -z "${target_tag}" ]]; then
        target_tag="$(curl -fsSL --retry 3 "https://api.github.com/repos/${CLEAN_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/' | head -1)"
    fi
    [[ "${target_tag}" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || _fail "ERROR: Could not resolve a stable Release tag"
    tmp_up="$(mktemp "${staging_root}/x-ui-clean-update-XXXXXXXX.sh")"
    if ! curl -fsSL --retry 3 "https://raw.githubusercontent.com/${CLEAN_REPO}/${target_tag}/scripts/update.sh" -o "${tmp_up}" || [[ ! -s "${tmp_up}" ]]; then
        rm -f "${tmp_up}"
        _fail "ERROR: Unable to download release-pinned update.sh"
    fi
    if bash "${tmp_up}" "${orig_args[@]}"; then
        rc=0
    else
        rc=$?
    fi
    rm -f "${tmp_up}"
    exit "${rc}"
fi

# If either half of an old installation remains, refuse to create fresh credentials.
if [[ -f "${xui_db_folder}/x-ui.db" || -f "${xui_folder}/x-ui" ]] && [[ "${force_fresh}" -eq 0 ]]; then
    _fail "ERROR: Partial existing installation detected; manual diagnosis required. Fresh installation would risk resetting credentials."
fi

# ------------------------------------------------------------------------------
# Process Mutex Lock (for fresh installation flow)
# ------------------------------------------------------------------------------
LOCK_DIR="/run/lock"
[[ -d "${LOCK_DIR}" ]] || LOCK_DIR="/tmp"
LOCK_FILE="${LOCK_DIR}/x-ui-clean-ops.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    _fail "ERROR: Another 3X-UI install/update/backup/rollback operation is already running (lock: ${LOCK_FILE})."
fi

# ------------------------------------------------------------------------------
# Fresh Installation Flow (Only runs when no existing x-ui installation exists)
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

gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "${length}" | head -n 1
}

# Install base dependencies in online mode only
if [[ -z "${offline_archive}" ]]; then
    echo -e "${green}[1/5] Checking base dependencies...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update -y >/dev/null 2>&1 && apt-get install -y -q curl tar tzdata socat openssl ca-certificates >/dev/null 2>&1 || true
            ;;
        centos | rhel | almalinux | rocky | ol | fedora)
            dnf install -y -q curl tar tzdata socat openssl ca-certificates >/dev/null 2>&1 || yum install -y -q curl tar tzdata socat openssl >/dev/null 2>&1 || true
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm curl tar tzdata socat openssl >/dev/null 2>&1 || true
            ;;
        alpine)
            apk update >/dev/null 2>&1 && apk add curl tar tzdata socat openssl ca-certificates >/dev/null 2>&1 || true
            ;;
    esac
fi

install -d -m 700 "${staging_root}"
free_kib="$(df -Pk "${staging_root}" | awk 'NR==2 {print $4}')"
[[ "${free_kib}" =~ ^[0-9]+$ && "${free_kib}" -ge 786432 ]] || _fail "ERROR: Need 768 MiB free space on disk-backed staging"
stage_dir="$(mktemp -d "${staging_root}/x-ui-install-stage-XXXXXXXX")"
trap 'rm -rf "${stage_dir}"' EXIT
archive_file="${stage_dir}/x-ui-linux-${TARGET_ARCH}.tar.gz"
bundled_scripts_dir=""

if [[ -n "${offline_archive}" ]]; then
    [[ ! -f "${offline_archive}" ]] && _fail "ERROR: Offline archive not found: ${offline_archive}"
    offline_abs="$(readlink -f "${offline_archive}")"
    echo -e "${green}[2/5] Validating offline archive: ${offline_abs}${plain}"
    [[ -f "${offline_abs}.sha256" ]] || _fail "ERROR: Missing offline .sha256 sidecar"
    (cd "$(dirname "${offline_abs}")" && sha256sum -c "$(basename "${offline_abs}.sha256")") || _fail "ERROR: Offline archive SHA256 mismatch!"
    tar -C "${stage_dir}" -xzf "${offline_abs}" || _fail "ERROR: Failed to extract offline archive."
    if [[ ! -f "${stage_dir}/x-ui/x-ui" ]]; then
        inner_tar="$(find "${stage_dir}" -type f -name "x-ui-linux-${TARGET_ARCH}.tar.gz" | head -n1 || true)"
        [[ -z "${inner_tar}" ]] && _fail "ERROR: Offline archive does not contain x-ui-linux-${TARGET_ARCH}.tar.gz"
        [[ -f "${inner_tar}.sha256" ]] || _fail "ERROR: Missing inner archive checksum"
        (cd "$(dirname "${inner_tar}")" && sha256sum -c "$(basename "${inner_tar}.sha256")") || _fail "ERROR: Inner archive SHA256 mismatch!"
        tar -C "${stage_dir}" -xzf "${inner_tar}" || _fail "ERROR: Failed to extract inner x-ui archive."
    fi
    bundled_scripts_dir="$(find "${stage_dir}" -maxdepth 2 -type d -name "scripts" | head -n1 || true)"
else
    if [[ -z "${target_tag}" ]]; then
        echo -e "${green}[2/5] Resolving latest release tag from ${CLEAN_REPO}...${plain}"
        target_tag="$(curl -fsSL --retry 3 --connect-timeout 15 "https://api.github.com/repos/${CLEAN_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)"
        if [[ -z "${target_tag}" ]]; then
            redirect_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 "https://github.com/${CLEAN_REPO}/releases/latest" 2>/dev/null || true)"
            target_tag="$(echo "${redirect_url}" | sed -n 's#.*/releases/tag/##p' | tr -d '[:space:]')"
        fi
        [[ -z "${target_tag}" ]] && _fail "ERROR: Could not resolve latest release tag from ${CLEAN_REPO}."
    fi

    download_url="https://github.com/${CLEAN_REPO}/releases/download/${target_tag}/x-ui-linux-${TARGET_ARCH}.tar.gz"
    sha_url="${download_url}.sha256"
    echo -e "${green}[2/5] Downloading 3X-UI Clean ${target_tag} (${TARGET_ARCH})...${plain}"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 -o "${archive_file}" "${download_url}" || _fail "ERROR: Failed to download ${download_url}"

    if curl -fsSL --retry 3 --connect-timeout 15 -o "${archive_file}.sha256" "${sha_url}"; then
        expected_sha="$(awk '{print $1}' "${archive_file}.sha256" | tr 'A-F' 'a-f')"
        actual_sha="$(sha256sum "${archive_file}" | awk '{print $1}' | tr 'A-F' 'a-f')"
        [[ "${expected_sha}" != "${actual_sha}" ]] && _fail "ERROR: SHA256 mismatch!"
    else
        _fail "ERROR: Missing checksum for online install archive"
    fi
    tar -C "${stage_dir}" -xzf "${archive_file}" || _fail "ERROR: Failed to extract downloaded archive."
fi

[[ ! -s "${stage_dir}/x-ui/x-ui" ]] && _fail "ERROR: Archive is missing x-ui binary."

if [[ "${TARGET_ARCH}" == "armv5" || "${TARGET_ARCH}" == "armv6" || "${TARGET_ARCH}" == "armv7" ]]; then
    mv -f "${stage_dir}/x-ui/bin/xray-linux-${TARGET_ARCH}" "${stage_dir}/x-ui/bin/xray-linux-arm32" 2>/dev/null || true
    if [[ -f "${stage_dir}/x-ui/bin/mtg-linux-${TARGET_ARCH}" ]]; then
        mv -f "${stage_dir}/x-ui/bin/mtg-linux-${TARGET_ARCH}" "${stage_dir}/x-ui/bin/mtg-linux-arm" 2>/dev/null || true
    fi
fi

echo -e "${green}[3/5] Installing files to ${xui_folder}...${plain}"
if systemctl is-active --quiet x-ui; then
    _fail "ERROR: x-ui service is already active; refusing fresh installation over a running service"
fi
mkdir -p "${xui_folder}/bin" "${xui_folder}/scripts" "${xui_db_folder}" "${xui_log_folder}" "${backup_root}"
chmod 700 "${backup_root}"

cp -rf "${stage_dir}/x-ui/." "${xui_folder}/"
chmod +x "${xui_folder}/x-ui" "${xui_folder}/x-ui.sh" 2>/dev/null || true
chmod +x "${xui_folder}"/bin/xray-linux-* "${xui_folder}"/bin/mtg-linux-* 2>/dev/null || true
cp -f "${xui_folder}/x-ui.sh" /usr/bin/x-ui
chmod +x /usr/bin/x-ui

if [[ -n "${bundled_scripts_dir}" && -d "${bundled_scripts_dir}" ]]; then
    cp -f "${bundled_scripts_dir}/"*.sh "${xui_folder}/scripts/" 2>/dev/null || true
    chmod +x "${xui_folder}/scripts/"*.sh 2>/dev/null || true
elif [[ -z "${offline_archive}" ]]; then
    for sname in backup.sh rollback.sh update.sh install.sh; do
        curl -fsSL --retry 3 --connect-timeout 10 \
            "https://raw.githubusercontent.com/${CLEAN_REPO}/main/scripts/${sname}" \
            -o "${xui_folder}/scripts/${sname}" 2>/dev/null && chmod +x "${xui_folder}/scripts/${sname}" || true
    done
fi

echo -e "${green}[4/5] Initializing panel credentials and database...${plain}"
"${xui_folder}/x-ui" migrate

settings_out="$("${xui_folder}/x-ui" setting -show true 2>/dev/null || true)"
has_default="$(echo "${settings_out}" | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}' | head -n1 || true)"
existing_webBasePath="$(echo "${settings_out}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -n1 || true)"
existing_port="$(echo "${settings_out}" | grep -Eo 'port: .+' | awk '{print $2}' | head -n1 || true)"

if [[ "${has_default}" == "true" ]]; then
    config_username="$(gen_random_string 10)"
    config_password="$(gen_random_string 10)"
    config_port="${XUI_PANEL_PORT:-$(shuf -i 10240-62000 -n 1 2>/dev/null || echo 38627)}"
    config_webBasePath="$(gen_random_string 18)"
    "${xui_folder}/x-ui" setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}" >/dev/null
    existing_port="${config_port}"
    existing_webBasePath="/${config_webBasePath}/"
    echo -e "${green}Generated Username    : ${config_username}${plain}"
    echo -e "${green}Generated Password    : ${config_password}${plain}"
fi

echo -e "${green}[5/5] Configuring and starting x-ui systemd service...${plain}"
if [[ "${release}" == "alpine" ]]; then
    cp -f "${xui_folder}/x-ui.rc" /etc/init.d/x-ui
    chmod +x /etc/init.d/x-ui
    rc-update add x-ui default >/dev/null 2>&1 || true
    rc-service x-ui start
else
    unit_src="${xui_folder}/x-ui.service.debian"
    case "${release}" in
        arch | manjaro | parch)
            [[ -f "${xui_folder}/x-ui.service.arch" ]] && unit_src="${xui_folder}/x-ui.service.arch"
            ;;
        centos | rhel | almalinux | rocky | ol | fedora | amzn)
            [[ -f "${xui_folder}/x-ui.service.rhel" ]] && unit_src="${xui_folder}/x-ui.service.rhel"
            ;;
    esac
    cp -f "${unit_src}" "${xui_service}/x-ui.service"
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
    systemctl start x-ui
fi

echo ""
echo -e "${green}═══════════════════════════════════════════════════════════════${plain}"
echo -e "${green}  3X-UI Clean Installed Successfully!                          ${plain}"
echo -e "${green}  Panel Port  : ${existing_port}${plain}"
echo -e "${green}  WebBasePath : ${existing_webBasePath}${plain}"
echo -e "${green}═══════════════════════════════════════════════════════════════${plain}"
