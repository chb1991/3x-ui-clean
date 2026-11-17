## v3.11.0 (2026-11-17)

- **Upstream Release**: [`MHSanaei/3x-ui@v3.11.0`](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0)
- **Upstream Commit**: `c621ba9014a6aa21fd7c9ecf45655e44e24ebf13`
- **License**: GNU GPL v3.0
- **Modifications Applied**:
  - Removed sponsor/ad backend service (`internal/web/service/panel/sponsor.go`) and outbound requests to `MHSanaei/sponsors`.
  - Removed `/sponsors` and `/sponsors/logo/:name` public endpoints from `internal/web/controller/index.go`.
  - Removed frontend sponsor slots (`LoginPage.tsx`, `IndexPage.tsx`), `/sponsors` route & menu entry (`panelRoutes.tsx`), and sidebar Donate link (`AppSidebar.tsx`).
  - Redirected in-panel & CLI self-updater (`panel.go`, `x-ui.sh`, `update.sh`, `install.sh`) to `chb1991/3x-ui-clean`.

### SHA256 Checksums
```text
e98a7439e5dee03382040b6e2ac7d7c5f58c06780763ba3800d533f6aa92031e  3x-ui-clean-v3.11.0-linux-amd64-offline.tar.gz
c67726de398a92c9c5157a4fe2c376adde929c6850abb14c0c4e27fb14a4bd66  3x-ui-clean-v3.11.0-linux-arm64-offline.tar.gz
a7de15a28e85f4a6a97a6e02a87ec079ff51cf3fb7d8aebf576b25d12f36c121  3x-ui-clean-v3.11.0-source.tar.gz
2061d9d51e73f3b06417a12f52ba1794a8c557d2c3f80795c956ef2ac0c6d577  x-ui-linux-amd64.tar.gz
abab1e7b766d852da65195c0037992dc1e1c414c59c9b152f3000c7838d3db2a  x-ui-linux-arm64.tar.gz
```

# 3X-UI Clean — Modification & Sync Changelog

This file records the upstream `MHSanaei/3x-ui` release version, commit hash, and exact modifications applied in each `3x-ui-clean` release in compliance with **GNU General Public License v3.0 (Section 5a)**.

---

## v3.11.0 (Initial Baseline)

- **Upstream Release**: [`MHSanaei/3x-ui@v3.11.0`](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0)
- **Upstream Commit**: `c621ba9014a6aa21fd7c9ecf45655e44e24ebf13`
- **License**: GNU GPL v3.0
- **Modifications Applied**:
  1. Removed backend sponsor/ad fetching service (`internal/web/service/panel/sponsor.go`, `sponsor_test.go`) and all outbound HTTP requests to `raw.githubusercontent.com/MHSanaei/sponsors`.
  2. Removed public `/sponsors` and `/sponsors/logo/:name` routes and handlers from `internal/web/controller/index.go` and route contract tests (`internal/web/routes_contract_test.go`).
  3. Removed `"Sponsor"` and `"SponsorList"` from OpenAPI/Zod codegen allowlist (`tools/openapigen/main.go`) and API documentation (`frontend/src/pages/api-docs/endpoints.ts`).
  4. Removed frontend sponsor components (`frontend/src/components/sponsor/*`), sponsor page (`frontend/src/pages/sponsors/*`), query hook (`frontend/src/api/queries/useSponsorsQuery.ts`), and localStorage helper (`frontend/src/lib/sponsors.ts`).
  5. Removed sponsor slots from `LoginPage.tsx` and `IndexPage.tsx`, removed `/sponsors` navigation entry from `panelRoutes.tsx` and `CommandPalette.tsx`, and removed `DonateButton` (`donate.sanaei.dev`) from `AppSidebar.tsx`.
  6. Redirected in-panel and CLI self-update endpoints (`internal/web/service/panel/panel.go`, `x-ui.sh`, `update.sh`, `install.sh`) to `chb1991/3x-ui-clean` so future updates never revert to the ad-supported build.
