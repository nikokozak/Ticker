# GitHub Backlog: Alpha (50 users / next month)

Use this document to create a GitHub Milestone and a set of Issues in a consistent order.

## Milestone

Create a Milestone:
- **Title:** `Alpha (50 users)`
- **Due date:** (next month, your target invite date)
- **Description:** “Signed+notarized Sparkle builds, Fly proxy with device keys + quotas, in-app Testing feedback, website waitlist/admin issuance.”

## Labels (recommended)

Create these labels (lightweight, useful):
- `alpha`
- `p0`, `p1`, `p2`
- `area:mac`, `area:web`, `area:swift`, `area:proxy`, `area:infra`, `area:docs`
- `type:bug`, `type:feature`, `type:chore`

## Issue format

For each Issue below:
- Add it to the `Alpha (50 users)` milestone
- Add the suggested labels
- Copy the Acceptance Criteria into the Issue body

---

## Epic A — Engineering workflow (blocks safe collaboration)

### A1 — Protect `main` + enforce PR workflow
- Labels: `alpha`, `type:chore`, `area:infra`, `p0`
- AC:
  - Branch protection enabled: PR required, 1 approval required, CI required
  - Direct pushes and force pushes to `main` disabled

### A2 — Add GitHub templates (issues + PR)
- Labels: `alpha`, `type:chore`, `area:docs`, `p0`
- AC:
  - Add `.github/ISSUE_TEMPLATE/bug.md` and `.github/ISSUE_TEMPLATE/feature.md`
  - Add `.github/pull_request_template.md` with: linked Issue, test plan, migration notes, rollback plan, changelog note

### A3 — Add CI (Swift build + Web typecheck)
- Labels: `alpha`, `type:chore`, `area:infra`, `p0`
- AC:
  - GitHub Actions runs:
    - `xcodebuild build -scheme Ticker -destination 'platform=OS X' -derivedDataPath .build/xcode`
    - `cd Web && npm run typecheck`
  - CI failure blocks merge

### A4 — Release discipline (versioning + changelog habit)
- Labels: `alpha`, `type:chore`, `area:docs`, `p0`
- AC:
  - Adopt `YYYY.MM.patch` release tags (documented)
  - Every user-facing PR adds a line to `CHANGELOG.md`

### A5 — Alpha test minimums documented
- Labels: `alpha`, `type:chore`, `area:docs`, `p1`
- AC:
  - `docs/TEST_STRATEGY.md` defines smoke coverage:
    - stream CRUD
    - persistence roundtrip
    - AI request flow
    - schema snapshot tests (bridge/proxy)

---

## Epic B — macOS distribution + data safety (blocks shipping)

### B1 — Entitlements audit
- Labels: `alpha`, `type:chore`, `area:mac`, `p0`
- AC:
  - Document required entitlements and why (Accessibility/hotkeys/persistence)
  - Remove any unused entitlements

### B2 — Standardize data location (Application Support) + migrate
- Labels: `alpha`, `type:feature`, `area:swift`, `p0`
- AC:
  - Data stored under `~/Library/Application Support/Ticker/`
  - Migration from `~/.config/ticker/` is automatic and safe
  - Pre-migration backup created

### B3 — SQLite backup-before-migration
- Labels: `alpha`, `type:feature`, `area:swift`, `p0`
- AC:
  - Before any DB schema migration runs, create a timestamped DB backup
  - Keep last N backups (choose N)

### B4 — Sparkle 2 integration (alpha channel)
- Labels: `alpha`, `type:feature`, `area:mac`, `p0`
- AC:
  - “Check for Updates…” exists
  - Sparkle updates from alpha appcast work end-to-end
  - Update prompt behavior acceptable for alpha testers

### B5 — Signed + notarized release runbook (initially local)
- Labels: `alpha`, `type:chore`, `area:mac`, `p0`
- AC:
  - Document exact steps to produce signed+notarized build and appcast update
  - Repeatable on the designated release machine

### B6 — Rollback support
- Labels: `alpha`, `type:feature`, `area:mac`, `p1`
- AC:
  - Appcast keeps last 2–3 releases
  - `/alpha` page documents manual downgrade/install steps

---

## Epic C — Proxy (Fly.io Phoenix) (blocks removing vendor keys)

### C1 — Phoenix proxy skeleton on Fly.io
- Labels: `alpha`, `type:feature`, `area:proxy`, `area:infra`, `p0`
- AC:
  - Deployed to Fly.io with TLS
  - Secrets managed via Fly secrets
  - Health endpoint present

### C2 — Device key issuance + storage (admin)
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- AC:
  - Admin can issue/revoke keys
  - Keys stored securely (never stored in plaintext; encrypted storage acceptable for alpha)
  - Key associated to user email + device label

### C3 — Device binding enforcement
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- AC:
  - First request binds key to `device_id`
  - Subsequent requests with different `device_id` → `401` with actionable message

### C4 — Ticker-native LLM request API (v1)
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- AC:
  - `POST /v1/llm/request` implemented for at least 1 provider
  - Returns `X-Ticker-Request-Id` for every response
  - Uses developer-owned provider keys (no user keys)

### C5 — Metering + quotas (req/min + daily + monthly)
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- AC:
  - Default limits: 20 req/min, 100k daily tokens, 1M monthly tokens
  - Per-key override supported in admin
  - Returns `429` with reset info when exceeded

### C6 — Diagnostics ingestion + 30-day retention
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- AC:
  - Endpoints for structured events and crash markers
  - Raw logs retained max 30 days (purge job)

### C7 — Feedback ingestion (bug + feature) with attachments
- Labels: `alpha`, `type:feature`, `area:proxy`, `p1`
- AC:
  - `POST /v1/feedback` supports `bug|feature`
  - Optional attachment upload (size cap, retention policy)
  - Returns `feedback_id`
  - Admin can view and export/copy feedback for manual GitHub promotion

### C12 — Vision: image prompts via proxy (message parts)
- Labels: `alpha`, `type:feature`, `area:proxy`, `p0`
- Depends on: `D8`
- AC:
  - `/v1/llm/request` accepts image inputs alongside text (a stable, documented message-parts format)
  - Proxy can forward multimodal requests to at least one provider (OpenAI) and return streaming SSE deltas
  - Quotas/rate limits apply to vision requests the same as text requests
  - No user/editor content is stored server-side; request logs remain metadata-only
  - Contract updated in `Ticker-Proxy/openapi/v1.yaml` (optional: vendor a pinned copy in `Ticker` for snapshot tests)

---

## Epic D — In-app alpha support + UX (reduces support load)

Implementation notes (source of truth for Epic D):
- Keep GitHub issues short; put implementation detail in this section.
- Read this once before starting D1–D6/D8.

### Epic D integration notes (Ticker ↔ Ticker-Proxy)

#### Product gate (main window)
- The main window “Streams” list is gated until a valid serial/device key is registered.
- If the key becomes invalid/revoked/bound-elsewhere, return to the gate and block stream access with an actionable message.
- Quota errors (`429`) should disable AI features but should not hide stream list access.

#### Storage rules (do not violate)
- Serial/device key is stored **only in Keychain** (Swift-side). Never store it in localStorage or logs.
- Device ID is generated once and stored in Keychain; it’s sent as `X-Ticker-Device-Id`.
- `X-Ticker-Request-Id` is treated as an opaque string; Ticker should send a UUID per request and surface it to the user on failures.

#### Proxy endpoints and auth models
- Header-auth endpoints (send `Authorization: Bearer <device_key>` + `X-Ticker-Device-Id`):
  - `POST /v1/auth/validate`
  - `POST /v1/llm/request` (sync + SSE when `stream: true`)
  - `POST /v1/diagnostics/event`, `POST /v1/diagnostics/crash`
- Key-in-body endpoints (send `device_key` in JSON body):
  - `POST /v1/feedback`
  - `POST /v1/feedback/{feedback_id}/attachments`
  - `POST /v1/feedback/{feedback_id}/attachments/{attachment_id}/complete`

#### Swift↔Web bridge messages to add (recommended contract)
Web → Swift:
- `loadProxyAuth`
- `setProxyDeviceKey` `{ deviceKey }` (store in Keychain; validate)
- `clearProxyDeviceKey`
- `validateProxyDeviceKey`
- `proxyLlmRequest` `{ provider?, model, messages, stream, ... }` (used by “think” path)
- `submitFeedback` `{ type, title, description, metadata?, relatedRequestId? }`
- `createFeedbackAttachment` `{ feedbackId, filename, contentType, byteSize }`
- `completeFeedbackAttachment` `{ feedbackId, attachmentId }`
- `copySupportBundle`

Swift → Web:
- `proxyAuthState` `{ state, supportId?, message?, limits?, usage?, lastRequestId? }`
- `proxyLlmDelta` / `proxyLlmDone` / `proxyLlmError` (or reuse existing `aiChunk/aiComplete/aiError` with proxy-shaped errors)
- `feedbackSubmitted` `{ feedbackId }`
- `attachmentCreated` `{ attachmentId, upload: { url, headers, expiresAt } }`
- `attachmentCompleted` `{ attachmentId, status }`
- `supportBundleCopied`

#### Vision (images in prompts): explicit scope
- Full “images in prompts” requires two issues:
  - `C12` (proxy accepts/forwards multimodal requests)
  - `D8` (Ticker extracts/serializes images and sends them to proxy)
- Do not send `ticker-asset://...` URLs to proxy; providers cannot fetch them.
- Pick one alpha-safe representation (recommended for alpha): **inline base64** image parts in the LLM request message parts:
  - `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<base64>"}}`
  - Keep images small (downsample/compress); the proxy enforces a base64 payload size cap (currently ~20MB) and will reject oversized requests.
  - Avoid URL images for alpha even if some providers support them; base64 is the simplest path and avoids “provider fetch” failure modes.

### D1 — Key entry + validation (Keychain)
- Labels: `alpha`, `type:feature`, `area:swift`, `area:web`, `p0`
- AC:
  - Main window stream list is gated until a valid serial/device key is registered
  - Settings allows entering a device key and validating it against proxy
  - Key stored in Keychain
  - Never display/log raw key; show `support_id` instead

### D2 — Usage UI + limit messaging
- Labels: `alpha`, `type:feature`, `area:web`, `p0`
- AC:
  - Show daily/monthly usage + caps + reset timing
  - Clear messages for quota exceeded

### D3 — Robust proxy error handling
- Labels: `alpha`, `type:feature`, `area:web`, `p0`
- AC:
  - Proxy unreachable: AI disabled, editor usable, clear message
  - `401`: invalid/bound-elsewhere key: prompt next step
  - `429`: quota exceeded: show usage + reset timing
  - `5xx`: retry affordance + request id
  - All AI requests route through the proxy (`/v1/llm/request`); the app does not require user-supplied provider API keys in order to use AI

### D4 — Request correlation captured and surfaced
- Labels: `alpha`, `type:feature`, `area:web`, `p1`
- AC:
  - App captures `X-Ticker-Request-Id` and includes it in support bundle

### D5 — “Testing” tab: bug report + feature request + support bundle
- Labels: `alpha`, `type:feature`, `area:web`, `p1`
- AC:
  - “Report a bug” and “Request a feature” forms
  - Optional attachment upload (screenshot)
  - “Copy Support Bundle” button (no content, no raw key)
  - Submits to proxy and returns `feedback_id` for the user to reference

### D6 — Diagnostics: default ON + disclosure + opt-out
- Labels: `alpha`, `type:feature`, `area:web`, `p1`
- AC:
  - First-run disclosure OR settings disclosure (acceptable)
  - Toggle to disable diagnostics
  - Default ON

### D7 — Export single stream (MD + text)
- Labels: `alpha`, `type:feature`, `area:web`, `p2`
- AC:
  - Export current stream to Markdown and plain text
  - Bulk export explicitly deferred

### D8 — Vision: send images in prompts via proxy
- Labels: `alpha`, `type:feature`, `area:swift`, `area:web`, `p0`
- Depends on: `C12`
- AC:
  - When a prompt includes images (screenshots or embedded images), Ticker sends a multimodal request to proxy using the C12 message-parts format
  - For alpha, Ticker uses **base64 image sources** (not URL images) and keeps payloads within the proxy’s size cap
  - Streaming responses render correctly (same UX as text streaming)
  - Clear UX when vision is unavailable (if `C12` disabled/unsupported provider/model)
  - No raw serial key, editor content, or full prompts are written to local logs or support bundle (only request ids and metadata)

---

## Epic E — Website + onboarding

### E1 — Landing + waitlist
- Labels: `alpha`, `type:feature`, `area:infra`, `p1`
- AC:
  - Landing page + waitlist form stored in DB

### E2 — Alpha + privacy + contact pages
- Labels: `alpha`, `type:feature`, `area:infra`, `p1`
- AC:
  - `/alpha`: expectations + update policy + how to send feedback
  - `/privacy`: diagnostics collected + opt-out + retention (30-day logs)
  - Contact page

### E3 — Status page
- Labels: `alpha`, `type:feature`, `area:infra`, `p2`
- AC:
  - `/status` shows proxy status (manual toggle acceptable)

### E4 — Admin approval → key issuance email
- Labels: `alpha`, `type:feature`, `area:infra`, `p1`
- AC:
  - Admin approves waitlist entry
  - System issues device key and emails instructions
