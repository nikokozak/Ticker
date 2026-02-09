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

## Running locally (when you come back in a month)

Preferred entry point: `./tickerctl.sh` (menu + scripted commands).

Common flows:
- Dev (Debug + Vite, stable lane): `./tickerctl.sh run-dev`
- Dev (Debug + Vite, QA lane): `./tickerctl.sh run-dev-qa`
- Prod-ish (Release + bundled web, stable lane): `./tickerctl.sh run-prod`
- Prod-ish (Release + bundled web, QA lane): `./tickerctl.sh run-prod-qa`

Permission debugging note:
- Stable lane uses bundle ID `io.ticker.app` (default).
- QA lane uses bundle ID `io.ticker.app.qa` (default) so TCC resets don't disrupt stable daily-dev permissions.
- Reset only the lane you are testing:
  - `./tickerctl.sh reset-accessibility`
  - `./tickerctl.sh reset-accessibility-qa`

Legacy runner (still supported):
- Dev: `./run.sh --dev`
- Dev (QA lane): `./run.sh --dev --qa`
- Prod: `./run.sh --prod`
- Prod (QA lane): `./run.sh --prod --qa`

If you hit SwiftPM/Sparkle artifact issues, run:
- `./tickerctl.sh clean-derived-data -y`

## Quick Panel (capture + ephemeral chat)

Quick Panel is the fast capture surface (hotkey-driven) and has two distinct modes:

- **Save** (`↵`): saves captured context and/or your input into a stream.
- **AI + Save** (`⌘↵`): saves, then triggers AI for the created cell.
- **Ask (ephemeral)** (`⌥↵`): runs an in-memory chat turn that is **not** saved to the stream DB.

Cancellation / escape behavior:
- `Esc` cancels streaming + clears the ephemeral chat (if active).
- Otherwise `Esc` clears input/context; a second `Esc` hides the panel.

## Drag & drop (native → stream)

You can drag files from Finder directly onto the app window:

- **Images** (`png/jpg/webp/heic/...`): saved to local assets and inserted into the editor as `ticker-asset://...`.
- **Documents** (`pdf/txt/md/...`): imported as Sources for the current stream.

Notes:
- Drops are routed to the **most recently opened stream**.
- If no stream has been opened yet, Ticker shows an error toast (“Open a stream before dropping files.”).

## Local data (what exists on disk)

Ticker stores user data under:
- `~/Library/Application Support/Ticker/`

Key items:
- `ticker.db` — the SQLite database (streams, cells, sources metadata)
- `assets/` — local images (inserted as `ticker-asset://...`)
- `backups/` — automatic pre-migration DB backups (created only when pending migrations are detected)
- `device.json` — **contains the plaintext proxy device key (`tk_...`) and device id**

If you need to restore data from a backup, follow the step-by-step instructions in `docs/ALPHA_SUPPORT.md`.

Device key rules:
- Never log the device key.
- Never ask a tester to send `device.json`.
- For “fresh install” QA, delete `device.json` while Ticker is fully quit, then relaunch.
- If you ever see stale temp files next to it, remove them too:
  - `~/Library/Application Support/Ticker/device.json.tmp*`
