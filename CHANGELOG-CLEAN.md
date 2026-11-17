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
