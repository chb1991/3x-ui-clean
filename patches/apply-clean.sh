#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Clean — Deterministic De-Ad & Self-Update Takeover Patch Script
# Repository: https://github.com/chb1991/3x-ui-clean
# License: GPL-3.0
# ==============================================================================
set -euo pipefail

UPSTREAM_DIR="${1:-.}"
CLEAN_REPO="${CLEAN_REPO:-chb1991/3x-ui-clean}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info()  { printf '\033[0;32m[CLEAN-PATCH]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[0;33m[CLEAN-WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[0;31m[CLEAN-ERROR]\033[0m %s\n' "$*" >&2; }

if [[ ! -d "${UPSTREAM_DIR}/.git" && ! -f "${UPSTREAM_DIR}/go.mod" ]]; then
    log_error "Target directory '${UPSTREAM_DIR}' is not a valid 3x-ui source tree."
    exit 1
fi

cd "${UPSTREAM_DIR}"
UPSTREAM_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
UPSTREAM_VER="$(tr -d '[:space:]' < internal/config/version 2>/dev/null || echo 'unknown')"
log_info "Applying 3X-UI Clean transformations to upstream v${UPSTREAM_VER} (${UPSTREAM_COMMIT})..."

# ------------------------------------------------------------------------------
# Step 1: Remove dedicated sponsor/ad files
# ------------------------------------------------------------------------------
log_info "Step 1/4: Removing dedicated sponsor and advertisement files..."
while IFS= read -r rel_path || [[ -n "${rel_path}" ]]; do
    rel_path="${rel_path%$'\r'}"
    [[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue
    if [[ -e "${rel_path}" ]]; then
        git rm -rf -q --ignore-unmatch -- "${rel_path}" 2>/dev/null || true
        rm -rf -- "${rel_path}"
        log_info "  Removed: ${rel_path}"
    fi
done < "${PATCH_DIR}/remove-files.txt"

# Clean up empty directories left behind
rmdir frontend/src/components/sponsor frontend/src/pages/sponsors 2>/dev/null || true

# ------------------------------------------------------------------------------
# Step 2: Apply 3-way minimal call-sites patch
# ------------------------------------------------------------------------------
log_info "Step 2/4: Applying 3-way call-sites patch (callsites.patch)..."
if ! git apply --3way --whitespace=nowarn "${PATCH_DIR}/callsites.patch"; then
    log_error "git apply --3way failed on callsites.patch! Upstream changed call-site context."
    git status --short
    exit 1
fi

# Clean dev proxy regex in frontend/vite.config.js if present
if [[ -f frontend/vite.config.js ]]; then
    sed -i 's/|sponsors|/|/g' frontend/vite.config.js
fi

# Safety check: if internal/web/controller/index.go no longer uses entity.*, strip its import
if [[ -f internal/web/controller/index.go ]]; then
    if ! grep -q 'entity\.' internal/web/controller/index.go; then
        sed -i '/"github.com\/mhsanaei\/3x-ui\/v3\/internal\/web\/entity"/d' internal/web/controller/index.go
    fi
fi

# ------------------------------------------------------------------------------
# Step 3: Redirect self-update & release endpoints to CLEAN_REPO
# ------------------------------------------------------------------------------
log_info "Step 3/4: Redirecting panel & CLI update URLs to ${CLEAN_REPO}..."

# 3.1 Go backend self-updater (internal/web/service/panel/panel.go)
if [[ -f internal/web/service/panel/panel.go ]]; then
    sed -i \
        -e "s|https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh|https://raw.githubusercontent.com/${CLEAN_REPO}/main/update.sh|g" \
        -e "s|https://api.github.com/repos/MHSanaei/3x-ui/releases|https://api.github.com/repos/${CLEAN_REPO}/releases|g" \
        internal/web/service/panel/panel.go
fi

# 3.2 Shell scripts (x-ui.sh, update.sh, install.sh)
for sh_file in x-ui.sh update.sh install.sh; do
    if [[ -f "${sh_file}" ]]; then
        sed -i \
            -e "s|raw.githubusercontent.com/MHSanaei/3x-ui|raw.githubusercontent.com/${CLEAN_REPO}|g" \
            -e "s|raw.githubusercontent.com/mhsanaei/3x-ui|raw.githubusercontent.com/${CLEAN_REPO}|g" \
            -e "s|api.github.com/repos/MHSanaei/3x-ui|api.github.com/repos/${CLEAN_REPO}|g" \
            -e "s|api.github.com/repos/mhsanaei/3x-ui|api.github.com/repos/${CLEAN_REPO}|g" \
            -e "s|github.com/MHSanaei/3x-ui/releases|github.com/${CLEAN_REPO}/releases|g" \
            -e "s|github.com/mhsanaei/3x-ui/releases|github.com/${CLEAN_REPO}/releases|g" \
            -e "s|/${CLEAN_REPO}/master/install.sh|/${CLEAN_REPO}/main/install.sh|g" \
            "${sh_file}"
    fi
done

# 3.3 Inject `x-ui backup` and `x-ui rollback` subcommands into x-ui.sh if not already present
if [[ -f x-ui.sh ]] && ! grep -q '"backup")' x-ui.sh; then
    sed -i 's|"update")|"backup")\n            /usr/local/x-ui/scripts/backup.sh "${@:2}"\n            ;;\n        "rollback")\n            /usr/local/x-ui/scripts/rollback.sh "${@:2}"\n            ;;\n        "update")|' x-ui.sh
fi

# ------------------------------------------------------------------------------
# Step 4: Strict Semantic Guard (Zero-Ad & Anti-Overwrite Verification)
# ------------------------------------------------------------------------------
log_info "Step 4/4: Running strict semantic guard checks..."

# 4.1 Check for unresolved merge conflicts
if git grep -n -E '^(<<<<<<<|=======|>>>>>>>)' -- internal frontend/src main.go tools 2>/dev/null; then
    log_error "Unresolved 3-way merge conflict markers detected!"
    exit 1
fi

# 4.2 Verify all dedicated sponsor files are gone
for removed in \
    internal/web/service/panel/sponsor.go \
    internal/web/service/panel/sponsor_test.go \
    frontend/src/components/sponsor/SponsorSlot.tsx \
    frontend/src/components/sponsor/SponsorCard.tsx \
    frontend/src/pages/sponsors/SponsorsPage.tsx \
    frontend/src/api/queries/useSponsorsQuery.ts \
    frontend/src/lib/sponsors.ts; do
    if [[ -e "${removed}" ]]; then
        log_error "Guard failed: '${removed}' still exists!"
        exit 1
    fi
done

# 4.3 Verify zero sponsor/ad/donate references remain in source code
FORBIDDEN_PATTERN='SponsorSlot|useSponsorsQuery|GetSponsors|GetSponsorLogo|DonateButton|DONATE_URL|donate\.sanaei|sponsors\.sanaei|MHSanaei/sponsors|pages/sponsors|lib/sponsors|"/sponsors"'
if git grep -n -E "${FORBIDDEN_PATTERN}" -- \
    internal frontend/src main.go tools \
    ':!internal/web/translation' \
    ':!frontend/src/generated' \
    ':!*_test.go' 2>/dev/null; then
    log_error "Guard failed: Residual sponsor/ad/donate references found in source code!"
    exit 1
fi

# 4.4 Verify panel.go points to CLEAN_REPO and not MHSanaei/3x-ui
if ! grep -q "https://raw.githubusercontent.com/${CLEAN_REPO}/main/update.sh" internal/web/service/panel/panel.go; then
    log_error "Guard failed: panelUpdaterURL in panel.go was not redirected to ${CLEAN_REPO}!"
    exit 1
fi
if ! grep -q "https://api.github.com/repos/${CLEAN_REPO}/releases/latest" internal/web/service/panel/panel.go; then
    log_error "Guard failed: fetchPanelRelease URL in panel.go was not redirected to ${CLEAN_REPO}!"
    exit 1
fi
if grep -q "MHSanaei/3x-ui" internal/web/service/panel/panel.go; then
    log_error "Guard failed: panel.go still contains a reference to MHSanaei/3x-ui!"
    exit 1
fi

log_info "All transformations and semantic guards passed successfully!"
