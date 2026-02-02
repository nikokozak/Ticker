# Start Here (Ticker Alpha)

This folder defines the “professional mode” workflow for Ticker and the minimum bar for a 50‑user alpha.

## Where to start (recommended order)

1) **Workflow + CI**
   - Read `docs/ENGINEERING_WORKFLOW.md`
   - Set up branch protections and CI described there
   - Start using Issues/PRs immediately (even for small fixes)

2) **Release discipline**
   - Read `docs/RELEASES.md`
   - Start updating `CHANGELOG.md` for every PR

3) **macOS shipping**
   - Read `docs/MAC_DISTRIBUTION.md`
   - Do entitlements audit (`docs/MAC_ENTITLEMENTS.md`)
   - Implement data location migration + backups (`docs/DATA_MIGRATIONS.md`) before inviting users

4) **Proxy + diagnostics**
   - Read `docs/PROXY_ARCHITECTURE.md` and `docs/PRIVACY_DIAGNOSTICS.md`
   - Use `docs/GITHUB_BACKLOG_ALPHA.md` as the canonical alpha issue list (Epic C/D integration notes included)

5) **Stability (2-week ship)**
   - Option A (single-call heading+body) + house-cleaning audit: `docs/ALPHA_STABILITY_PLAN.md`

6) **Alpha ops**
   - Read `docs/ALPHA_READINESS_CHECKLIST.md`
   - Read `docs/ALPHA_SUPPORT.md` (in-app feedback → manual triage)
   - Read `docs/WEBSITE_REQUIREMENTS.md`

## How to run the process (every change)

1) Create a GitHub Issue with acceptance criteria.
2) Create a branch: `fix/<issue-123>-slug` or `feature/<slug>`.
3) Make a small PR.
4) CI must pass; reviewer approves; merge to `main`.
5) If user-facing: add 1 entry to `CHANGELOG.md`.
6) For releases: follow `docs/RELEASES.md` (tagged, repeatable build, rollback plan).

## Alpha posture

- Prefer “boring and reliable” over “clever”.
- Never ship a migration without a backup and a downgrade story.
- Treat the proxy request ID as your primary debugging handle.

## Local data + secrets (don’t lose this)

All user data lives under:
- `~/Library/Application Support/Ticker/`

Important files:
- `ticker.db` — the user’s SQLite database
- `assets/` — local images
- `device.json` — **contains the plaintext proxy device key (`tk_...`) and device id**

Rules:
- Never log the device key.
- Never ask a tester to send `device.json`.
- For “fresh install” QA, delete `device.json` while Ticker is fully quit, then relaunch.
