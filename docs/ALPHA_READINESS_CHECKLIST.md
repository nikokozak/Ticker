# Alpha Readiness Checklist (50 users / next month)

This checklist is what “ready to invite users” means for Ticker alpha.

## Blocking (must be true before inviting users)

### Workflow + safety
- `main` is protected (PR required, CI required, no direct pushes)
- `CHANGELOG.md` exists and is updated per release
- Release process documented (`docs/RELEASES.md`)

### macOS distribution
- Signed + notarized build can be produced repeatably
- Sparkle 2 integrated (“Check for Updates…”)
- Appcast published at a stable URL
- Rollback supported (last 2–3 releases available)

### Data safety
- Data stored in `~/Library/Application Support/Ticker/`
- Backup created before any DB migration
- Migration failures are handled without destroying user data

### Proxy
- Proxy deployed on Fly.io
- Per-device keys supported; key binding enforced
- Per-minute + daily + monthly quotas enforced
- Proxy returns `X-Ticker-Request-Id` for every request (treat as an opaque string; Ticker should send a UUID per request)
- Logs retained for max 30 days; purge job in place

### In-app alpha support
- Key entry + validation exists (Keychain storage)
- Settings shows usage + limits + reset timing
- Clear UX for: offline, invalid key, quota exceeded, server errors
- “Report bug / request feature” flow exists with optional attachments
- “Copy Support Bundle” exists (no note content)
- Diagnostics default ON with disclosure + opt-out toggle

Implementation reference:
- `docs/GITHUB_BACKLOG_ALPHA.md` (Epic D integration notes + acceptance criteria)

### Website
- Landing + waitlist
- `/alpha` (alpha expectations + update policy)
- `/privacy` (what diagnostics are collected + retention)
- `/status` (manual is acceptable)
- Contact method

## Nice-to-have (can ship after first invites)

- Single-stream export (MD/text)
- Admin dashboards beyond basic triage
- Provider fallback policies
