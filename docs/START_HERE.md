# Start Here (Ticker-Next)

## Status

Current editor direction is defined by:
- `docs/TICKER_NEXT_MVP_PLAN.md`
- `docs/EDITOR_TECH_DECISION.md`

Ticker-Next preserves Ticker's app/window flow and focuses iteration on the in-stream editor only.
If other docs conflict with the MVP plan, follow the MVP plan.
Critical constraints from the MVP plan:
- no native editor
- no cell-based editor model
- no persistent split-pane writing layout
- images + PDF highlight linking are required capabilities

This folder defines the “professional mode” workflow for Ticker and the minimum bar for a 50‑user alpha.

## Where to start (recommended order)

1) **Workflow + CI**
  - Read `docs/ENGINEERING_WORKFLOW.md`
  - Set up branch protections and CI described there
  - Start using Issues/PRs immediately (even for small fixes)

2) **Product direction (required)**
   - Read `docs/TICKER_NEXT_MVP_PLAN.md`
   - Read `docs/EDITOR_TECH_DECISION.md`
   - Treat these as canonical for editor UX/implementation direction

3) **Release discipline**
  - Read `docs/RELEASES.md`
  - Start updating `CHANGELOG.md` for every PR

4) **macOS shipping**
  - Read `docs/MAC_DISTRIBUTION.md`
  - Do entitlements audit (`docs/MAC_ENTITLEMENTS.md`)
  - Implement data location migration + backups (`docs/DATA_MIGRATIONS.md`) before inviting users

5) **Proxy + diagnostics**
  - Read `docs/PROXY_ARCHITECTURE.md` and `docs/PRIVACY_DIAGNOSTICS.md`
  - Read `docs/contracts/README.md` before editing bridge payloads
  - Use `docs/GITHUB_BACKLOG_ALPHA.md` as a working alpha issue list for non-editor operational work

6) **Alpha ops**
  - Read `docs/ALPHA_READINESS_CHECKLIST.md`
  - Read `docs/ALPHA_SUPPORT.md` (in-app feedback → manual triage)
  - Read `docs/WEBSITE_REQUIREMENTS.md`

## How to run the process (every change)

1) Create a GitHub Issue with acceptance criteria.
2) Create a branch: `codex/<issue-123>-slug` (or team branch convention if not using Codex).
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
- Stable lane uses bundle ID `io.ticker.next` (default).
- QA lane uses bundle ID `io.ticker.next.qa` (default) so TCC resets don't disrupt stable daily-dev permissions.
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

Quick Panel is the fast capture surface (hotkey-driven) and has three distinct modes:

- **Save** (`↵`): appends captured context and/or your input directly to the selected stream document, shows “Saved to <stream>”, then hides.
- **Save + develop** (`⌘↵`): appends to the selected stream document, confirms the destination while hiding, then develops it with AI in the background.
- **Chat here** (`⌥↵`): runs an in-memory chat turn that is **not** saved to the stream DB. Individual replies can still be saved explicitly.

Cancellation / escape behavior:
- During active AI streaming, `Esc` cancels the request and restores the prompt for editing.
- Otherwise, `Esc` closes the panel in one press and keeps the typed draft for the next opening.
- Clicking outside also closes the panel and keeps the typed draft. Context and conversations have their own clear buttons.

## Drag & drop (native → stream)

You can drag files from Finder directly onto the app window:

- **Images** (`png/jpg/webp/heic/...`): saved to local assets and inserted into the editor as `ticker-asset://...`.
- **Documents** (`pdf/txt/md/...`): imported as Sources for the current stream.

Notes:
- Drops are routed to the **most recently opened stream**.
- If no stream is open, dropping a PDF creates a new stream; other files show “Drop files in a stream, or return to Streams to create one from PDF.”

## Local data (what exists on disk)

Ticker stores user data under:
- `~/Library/Application Support/Ticker-Next/`

Key items:
- `ticker.db` — the SQLite database (streams, `stream_documents`, sources metadata, and frozen legacy migration history)
- `assets/` — local images (inserted as `ticker-asset://...`)
- `backups/` — automatic pre-migration DB backups (created only when pending migrations are detected)
- `device.json` — **contains the plaintext proxy device key (`tk_...`) and device id**

Document model:
- `stream_documents.markdown` is the canonical editor content for a stream.
- `stream_documents.revision` is the autosave conflict guard.
- The `cells` table is frozen legacy history kept for migrations/recovery; it is not the active editor or capture contract.

If you need to restore data from a backup, follow the step-by-step instructions in `docs/ALPHA_SUPPORT.md`.

Device key rules:
- Never log the device key.
- Never ask a tester to send `device.json`.
- For “fresh install” QA, delete `device.json` while Ticker is fully quit, then relaunch.
- If you ever see stale temp files next to it, remove them too:
  - `~/Library/Application Support/Ticker-Next/device.json.tmp*`
