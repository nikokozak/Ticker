# Alpha Support & Triage

Alpha support is designed to be fast and low-friction for users while keeping sensitive data out of logs.

## Local secret storage (critical)

Ticker stores the **proxy device key** and a generated **device id** on disk at:

- `~/Library/Application Support/Ticker/device.json`

Important notes:
- This file contains the **plaintext device key** (`tk_...`). Treat it as a secret.
- Never ask testers to send `device.json` (and never include it in screenshots / screen recordings).
- Support workflows must use **Support ID** + **Request IDs**, not the raw key.

### Reset instructions (for internal QA only)

Use this when you need to simulate a “fresh install” / new device identity:

1) Quit Ticker completely.
2) Remove the file: `~/Library/Application Support/Ticker/device.json`
3) Relaunch Ticker and re-enter a device key in Settings.

If you ever see any stale temp files next to it (should not happen after the fix for issue #51), remove them too:
- `~/Library/Application Support/Ticker/device.json.tmp*`

## In-app support surface

Add a “Testing” (or Settings) section with:

- **Report a bug**
- **Request a feature**
- **Copy Support Bundle**
- Optional: view recent proxy request IDs

## Bug report payload (recommended)

Include:
- Title, description, steps, expected/actual
- `support_id` (derived; not the key)
- app version, OS version
- last N proxy request IDs
- recent structured error summaries
- Optional attachment (screenshot), with warning it may contain content

Exclude:
- raw device key
- note/editor content by default

## Feature request payload

Include:
- Title, description, why it matters
- Optional attachment

Do not include logs by default.

## Data recovery (SQLite backups)

Ticker stores user data at:
- `~/Library/Application Support/Ticker/ticker.db`

When Ticker detects pending schema migrations on launch, it attempts to create a pre-migration backup at:
- `~/Library/Application Support/Ticker/backups/ticker-YYYYMMDD-HHMMSS.db`

### Restore from a backup (local-only)

1) Quit Ticker completely.
2) Open `~/Library/Application Support/Ticker/` in Finder.
3) Make a safety copy of the current DB:
   - Rename `ticker.db` → `ticker.db.broken` (or copy it elsewhere).
4) Pick the newest backup in `backups/` and copy it next to the DB.
5) Rename that backup to `ticker.db`.
6) Launch Ticker and verify your streams/editor content are back.

Notes:
- This only restores local note data. It does not affect your proxy/device key state.
- If you’re reporting a migration issue, include the backup filename and the app version you upgraded from/to.

## Manual promotion workflow

1) Feedback arrives in proxy admin as `bug` or `feature`.
2) You triage and, if actionable, manually create a GitHub Issue:
   - Copy the user text
   - Include `feedback_id` and recent request IDs
3) Label severity and scope:
   - `alpha-bug`, `alpha-feature`, `p0/p1/p2`, `needs-info`

## Service expectations

- Errors shown to users must include a copyable request ID or feedback ID.
- When proxy quota is exceeded, show reset timing and a next step.

## Drag & drop troubleshooting (files from Finder)

Expected behavior:
- Dropping an image inserts it into the current stream as a `ticker-asset://...` image.
- Dropping a PDF/text file adds it as a Source to the current stream.

Common failures:
- **“Open a stream before dropping files.”**: open any stream first (drops go to the most recently opened stream).
- **“Could not import that image.”**: try re-exporting the image (some apps produce odd containers), or try a PNG/JPG.
- **Source import fails**: capture the exact error toast text and include it in the bug report.

## Quick Panel support notes

When triaging Quick Panel bugs, always ask which mode was used:
- `↵` save
- `⌘↵` AI+save
- `⌥↵` ask (ephemeral; not saved)

Repro checklist for testers:
- Was there captured context (selection or screenshot)?
- Did streaming start, and did it stop when pressing `Esc`?
- If using `⌥↵`: confirm no new persisted stream content was created after app restart.
