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
   - Implement device keys, metering/quotas, request correlation, and 30‑day log retention

5) **Alpha ops**
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

## Local data (what exists on disk)

Ticker stores user data under:
- `~/Library/Application Support/Ticker/`

Key items:
- `ticker.db` — the SQLite database (streams, cells, sources metadata)
- `backups/` — automatic pre-migration DB backups (created only when pending migrations are detected)

If you need to restore data from a backup, follow the step-by-step instructions in `docs/ALPHA_SUPPORT.md`.
