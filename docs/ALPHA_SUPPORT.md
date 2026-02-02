# Alpha Support & Triage

Alpha support is designed to be fast and low-friction for users while keeping sensitive data out of logs.

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

## Quick Panel support notes

When triaging Quick Panel bugs, always ask which mode was used:
- `↵` save
- `⌘↵` AI+save
- `⌥↵` ask (ephemeral; not saved)

Repro checklist for testers:
- Was there captured context (selection or screenshot)?
- Did streaming start, and did it stop when pressing `Esc`?
- If using `⌥↵`: confirm no new stream/cell was created and nothing persisted after app restart.
