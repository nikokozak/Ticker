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
