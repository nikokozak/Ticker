# Ticker ↔ Ticker-Proxy Integration (Epic D)

This document is a detailed implementation guide for integrating the completed `ticker-proxy` server (Phoenix/Fly) into the Ticker macOS app (Swift + React/WKWebView).

Status note (to reduce doc bloat):
- The canonical “what to build next” lives in `docs/GITHUB_BACKLOG_ALPHA.md` (Epic D + D8, and C12 for vision).
- This file is a deep-dive reference. If it drifts, treat `docs/GITHUB_BACKLOG_ALPHA.md` as the source of truth.

Related docs:
- Backlog + issue AC: `docs/GITHUB_BACKLOG_ALPHA.md` (Epic D)
- Alpha ship checklist: `docs/ALPHA_READINESS_CHECKLIST.md`
- Privacy/diagnostics rules: `docs/PRIVACY_DIAGNOSTICS.md`
- Proxy overview: `docs/PROXY_ARCHITECTURE.md`

## Goals

- Gate the **main window stream list** behind a valid serial (device) key.
- Store the serial key **only in Keychain** (never in localStorage), and never display it after save.
- Use the proxy for:
  - Key validation + binding (`/v1/auth/validate`)
  - LLM requests (sync + SSE streaming) (`/v1/llm/request`)
  - Feedback + attachments (`/v1/feedback` + attachments endpoints)
  - Diagnostics + crash markers (`/v1/diagnostics/*`)
- Surface robust user-facing errors for:
  - Auth issues: missing/invalid/revoked/bound-elsewhere
  - Quotas: req/min + token/day + token/month
  - Upstream: 502 + request id correlation
- Capture and surface `X-Ticker-Request-Id` for support (toasts + support bundle).
- Default diagnostics ON with an opt-out toggle.

## Non-goals (for this integration slice)

- Billing, self-serve onboarding, or automatic GitHub issue creation.
- Re-architecting the entire AI pipeline; focus on swapping the network target to `ticker-proxy` with minimal disruption.
- Perfect streaming request logging parity (proxy already documents that request log duration is time-to-first-byte for SSE).

## Source of truth: API contract

- The machine-readable contract lives in the proxy repo: `Ticker-Proxy/openapi/v1.yaml`.
- Optional (only if you want snapshot tests / offline review): vendor a pinned copy for client dev:
  - `Ticker/docs/openapi/ticker-proxy-v1.yaml` (copied from proxy repo on updates)

## Terminology (client-side)

- **Serial key / device key**: the string issued by proxy admin; used as `Authorization: Bearer <key>`.
- **Support ID**: non-secret identifier returned by `/v1/auth/validate` (safe to show to user).
- **Device ID**: per-install UUID used for binding via `X-Ticker-Device-Id`.
- **Request ID**: client-generated UUID per request (recommended) set as `X-Ticker-Request-Id`; proxy echoes/returns it in response headers. Treat it as an opaque string (not guaranteed to be a UUID).

## UX spec: Registration gate (Main Window)

### Where it appears

- In the main window **stream list view** (`Web/src/App.tsx` view `list`), replace the “Streams” list with a registration gate when the app is not in an “active” auth state.

### What it shows

- Title: “Register Ticker”
- Body text (short): “Enter your serial key to register this device.”
- Input: serial key (password-style with optional reveal toggle).
- Primary button: “Validate & Register”
- Secondary actions:
  - “Paste from clipboard”
  - “Open Help” (goes to new Help/Testing view)
- Status area:
  - Success: show `support_id` and “Registered to this device”
  - Error: show a clear explanation and next step

### What blocks the app

Block the stream list and any actions that open a stream when:

- No serial key is stored, or
- Stored key fails validation for auth reasons:
  - `invalid_key`
  - `key_revoked`
  - `key_bound_elsewhere`

**Do not** permanently “block the whole app” for quota errors:

- `rate_limit_exceeded` / `token_budget_exceeded` should disable AI calls and show messaging, but should not hide the stream list. (This preserves local-first usefulness and avoids user confusion.)

## State machine (single source of truth)

Implement an explicit auth state machine in Swift and mirror it in Web UI. The Swift side owns the “truth”; Web renders it.

Recommended states:

1. `unregistered`
   - No key stored.
2. `validating`
   - Key exists or user entered a key; validate call in flight.
3. `active`
   - Key valid for this device. Includes `support_id`, `limits`, `usage`, `bound_device_id`.
4. `blocked_invalid`
   - Key missing/invalid.
5. `blocked_revoked`
   - Key revoked.
6. `blocked_bound_elsewhere`
   - Key bound to another device.
7. `degraded_offline`
   - Network unreachable / proxy unreachable *while validating*.
   - (If already `active`, keep stream list accessible but disable AI features and show a toast banner.)

## Architecture: where proxy networking should live

Ticker is Swift + WebView. The least-risk integration is:

- **Swift** performs all authenticated proxy calls (because it owns Keychain).
- **Web** is responsible for UI, file selection, and requesting operations via bridge messages.
- **Web** can upload attachments directly to presigned PUT URLs (no key required) and then tells Swift to “complete” the upload.

This keeps the device key out of JS persistent storage and reduces accidental logging.

## Implementation plan (mapped to Epic D issues)

### D1 — Key entry + validation (Keychain) + main-window gate

#### D1a — Swift: persist `device_id` + `device_key` in Keychain

Add new Keychain keys via `KeychainService` (or via `SettingsService` wrappers):

- `proxy_device_key` (serial key)
- `proxy_device_id` (UUID string)

Device ID generation:

- On first access, generate `UUID().uuidString`, save to Keychain, and reuse forever.
- Device ID should be available before any proxy request.

Serial key storage rules:

- Never log the full key.
- Provide helper methods:
  - `getDeviceKey() -> String?`
  - `setDeviceKey(_:)` (trims whitespace; rejects empty)
  - `clearDeviceKey()`

#### D1b — Swift: `TickerProxyClient.validate()`

Add a lightweight proxy HTTP client in Swift (new file recommended):

- `Sources/Ticker/Services/Proxy/TickerProxyClient.swift`

Base URL configuration:

- Prod default: `https://ticker-proxy.fly.dev`
- Allow override via environment variable in Debug builds (e.g., `TICKER_PROXY_BASE_URL`) for local testing.

Headers for **header-auth** endpoints:

- `Authorization: Bearer <device_key>`
- `X-Ticker-Device-Id: <uuid>`
- `X-Ticker-App-Version: <app version>` (from bundle)
- `X-Ticker-Platform: macOS`
- `X-Ticker-OS-Version: <macOS version>`
- `X-Ticker-Request-Id: <string>` (ticker should generate a UUID per request; proxy echoes/returns it)

Validate call:

- `POST /v1/auth/validate` (empty JSON body is fine; proxy ignores params)
- Parse JSON:
  - `support_id`
  - `bound_device_id`
  - `limits`
  - `usage`
- Capture response header:
  - `X-Ticker-Request-Id`

Mapping to auth states:

- 200 → `active`
- 401 + `error.code`:
  - `invalid_key` → `blocked_invalid`
  - `key_revoked` → `blocked_revoked`
  - `key_bound_elsewhere` → `blocked_bound_elsewhere`
  - `missing_auth` / `invalid_auth` → treat as `blocked_invalid` (client bug)
- Network errors / timeout → `degraded_offline` if validating; if already `active`, keep `active` but set a “proxy offline” banner state.

#### D1c — Swift ↔ Web: bridge message contract for auth

Add new bridge messages handled in `Sources/Ticker/App/WebViewManager.swift`:

Web → Swift:

- `loadProxyAuth` (fire-and-forget)
- `setProxyDeviceKey` `{ deviceKey: string }` (store in Keychain; then validate)
- `clearProxyDeviceKey` (delete key; respond with state = unregistered)
- `validateProxyDeviceKey` (force validate; useful for retry)

Swift → Web:

- `proxyAuthState` payload:
  - `state`: one of the state strings above
  - `supportId?`
  - `message?` (human text for gate screen)
  - `lastRequestId?` (for support)
  - `limits?` and `usage?` (for D2)
  - `proxyReachable?` (boolean)

Recommended behavior:

- On app boot, Swift should immediately compute state:
  - if key exists → send `proxyAuthState(validating)` then call validate and send updated state
  - else → send `proxyAuthState(unregistered)`

#### D1d — Web: implement Registration Gate component

New component recommended:

- `Web/src/components/ProxyRegistrationGate.tsx`

State ownership:

- Web stores the latest `proxyAuthState` from Swift in React state (or Zustand store).
- On mount, Web sends `loadProxyAuth`.

UX rules:

- Only show the gate when `state` is `unregistered|validating|blocked_*|degraded_offline`.
- If `active`, show the stream list as normal.

Do not keep the serial key in localStorage.

### D2 — Usage UI + limit messaging

#### D2a — Where to show usage

Minimum viable:

- In Settings UI (or a new “Account” section), display:
  - `support_id`
  - req/min limit and current minute usage
  - tokens/day used + limit + reset timestamp
  - tokens/month used + limit + reset timestamp

Optional:

- Show a small “Usage” footer on the stream list view when `active`.

#### D2b — When to refresh usage

Keep it cheap:

- After `auth/validate` on boot.
- After any AI request completes (sync or stream done) call `auth/validate` in the background (or rely on the proxy response usage + only refresh on errors).
- When a 429 occurs, call validate to show updated usage.

### D3 — Robust proxy error handling (centralized)

#### D3a — Define a single error model (Swift) and map to user strings

Add a `ProxyError` type:

- `kind`: `auth|quota|upstream|network|validation|internal`
- `code`: proxy `error.code` or a synthetic code
- `message`: user-facing string
- `details`: optional dictionary (e.g., reset times)
- `requestId`: `X-Ticker-Request-Id` if available

Mapping rules (user-facing):

- Auth failures → gate screen, with next step text.
- Quota failures (`429`) → allow app usage but disable AI actions; show a banner/toast:
  - Use `Retry-After` + `reset_at` for countdown text.
- Upstream failures (`502`) → toast with “Try again” and include request id copy affordance.
- Network unreachable → toast/banner “Proxy unreachable; AI disabled” (do not gate if previously active).

#### D3b — Web error display

Continue using `ToastStack` and `useToastStore`.

Extend the `aiError` payload from Swift to include:

- `requestId` (string)
- `code` (proxy error code)
- `details?` (serialized)

Then render:

- Toast message: short
- Secondary line: “Request ID: … (click to copy)” (optional)

### D4 — Request correlation captured and surfaced

#### D4a — Always generate a request id per proxy call

In Swift `TickerProxyClient`, generate a UUID string for each request and set:

- `X-Ticker-Request-Id`

Then capture:

- Response `X-Ticker-Request-Id` (if proxy overwrote or echoed)

#### D4b — Support bundle

Add a “Copy Support Bundle” button in Help/Testing view (D5).

Bundle contents (no content; no raw key):

- `support_id`
- `device_id` (OK; not secret)
- app version + build
- macOS version
- proxy base URL
- current proxy auth state
- last N request IDs seen (from recent AI errors + last AI success)
- last quota error details (if any)
- diagnostics enabled toggle state

Implementation approach:

- Web asks Swift: `bridge.sendAsync('copySupportBundle')`
- Swift builds a text payload and uses NSPasteboard to copy it.
- Swift sends back `supportBundleCopied` for UI toast.

### D5 — “Testing / Help” tab: feedback + attachments

#### D5a — UI placement

Add a “Help” (or “Testing”) view accessible from the stream list header alongside Settings.

Recommended:

- Extend `Web/src/App.tsx` view union to include `help`.
- Add `Help` button in stream list header.

#### D5b — Feedback submission flow (no auth screen; uses stored key)

Proxy endpoints:

- `POST /v1/feedback`
- `POST /v1/feedback/{feedback_id}/attachments`
- `POST /v1/feedback/{feedback_id}/attachments/{attachment_id}/complete`

Important: feedback endpoints use **key-in-body** (`device_key` field) and do not require `X-Ticker-Device-Id`.

Recommended implementation:

Web → Swift bridge:

- `submitFeedback` payload:
  - `type`: `"bug"|"feature"`
  - `title`
  - `description`
  - `metadata` (object; keep small)
  - `relatedRequestId?`
- Swift:
  - pulls stored `device_key`
  - calls `/v1/feedback`
  - returns `feedback_id`

Metadata fields to include (safe, non-content):

- `support_id`
- `app_version`, `os_version`, `platform`
- `proxy_base_url`
- `stream_id?` (UUID) (optional)
- `last_request_id?`

#### D5c — Attachments (presigned PUT)

Preferred flow (key never enters JS):

1. Web selects a file (e.g., screenshot).
2. Web asks Swift to create attachment:
   - `createFeedbackAttachment` payload:
     - `feedbackId`
     - `filename`
     - `contentType`
     - `byteSize`
   - Swift calls `/v1/feedback/{feedback_id}/attachments` with `device_key` in body.
   - Swift returns:
     - `attachmentId`
     - `upload.url`
     - `upload.headers`
     - `upload.expires_at`
3. Web uploads bytes to `upload.url` via `fetch(url, { method: 'PUT', headers, body })`.
4. Web tells Swift `completeFeedbackAttachment`:
   - Swift calls `/complete` with `device_key` in body.
5. Web shows “Uploaded” badge and includes attachment count.

Failure handling:

- Upload PUT fails → show retry; do not call complete.
- Complete returns:
  - `upload_not_found` → tell user “upload did not finish; retry upload”
  - `upload_too_large` / `size_mismatch` → tell user “file too large/changed”; re-create attachment.

#### D5d — User-facing response

After submit:

- Show `feedback_id` and a “Copy feedback ID” button.
- Mention “Include this ID in support messages.”

### D6 — Diagnostics: default ON + disclosure + opt-out

#### D6a — Settings toggle

Add a boolean `diagnosticsEnabled` setting (default ON).

- Store in UserDefaults (non-sensitive).
- Expose in Web Settings (or Help) UI.

#### D6b — What to send

Use proxy endpoints:

- `POST /v1/diagnostics/event` for structured events
- `POST /v1/diagnostics/crash` for crash markers

Attach these fields (no note content):

- `type`: `"event"` or `"crash"` (proxy uses fixed types)
- payload: structured object with:
  - `name` (e.g., `"proxy_auth_failed"`, `"ai_request_failed"`)
  - `support_id`
  - `request_id` (if known)
  - `error_code` and `status` (if any)
  - app/os versions

#### D6c — Where to hook

Minimum viable hooks:

- When `auth/validate` fails with auth codes → send diagnostic event (if enabled).
- When `/v1/llm/request` fails (502/429/400) → send diagnostic event (if enabled), including request id and error code.
- When streaming encounters `client_disconnected`, do **not** send diagnostics (user canceled).

Optional (later):

- JS global error boundary for UI exceptions (be careful not to include editor content).

## LLM request integration details (core of D3)

### Replace direct provider calls with proxy calls (Swift)

Today, Swift streams directly from OpenAI/Anthropic/Perplexity in:

- `Sources/Ticker/Services/AIService.swift`
- `Sources/Ticker/Services/AnthropicService.swift`
- `Sources/Ticker/Services/PerplexityService.swift`

To integrate proxy with minimal churn:

1. Add a new provider implementation: `ProxyLLMProvider` that conforms to `LLMProvider`.
2. Register it in `AIOrchestrator` (as the default provider) when `proxy_device_key` exists and is valid.
3. Update the UI error strings for `LLMProviderError.notConfigured` to refer to serial key registration instead of “API key”.

### Streaming format (SSE)

Proxy streaming format is SSE with explicit `event:`:

- `event: delta` + `data: {"text":"..."}`
- `event: done` + `data: {"usage":{...}}`
- `event: error` + `data: {"error":{...}}`

Implement a small SSE parser in Swift (new file recommended):

- `Sources/Ticker/Services/Proxy/SSEParser.swift`

Rules:

- Handle CRLF/LF
- Support `data:` with or without trailing space
- Accumulate chunks until newline; parse line by line
- Track current `event` type; apply `data` to it

Mapping:

- `delta` → call `onChunk(text)`
- `done` → store usage; call `onComplete()`
- `error` → build `ProxyError`; call `onError(error)` (and include request id)

### Usage recording

Proxy will enforce budgets; client should:

- Treat `429 token_budget_exceeded` as a “disable AI until reset” condition.
- Display reset time from `details.reset_at` and optionally `Retry-After`.

## Known gaps / decisions to make before coding

### Vision / image support

Proxy supports multimodal prompts via `Message.content`:
- Text-only: `content` is a string
- Multimodal: `content` is an array of parts (`text` and `image`)

Keep it lightweight for alpha: **always use base64 image parts** (do not rely on URL images).

Why:
- Avoids provider “fetch this URL” failure modes
- Avoids accidentally sending local-only URLs (`ticker-asset://...`) that providers cannot fetch

Request shape (one message example):
```json
{
  "role": "user",
  "content": [
    { "type": "text", "text": "What's in this image?" },
    { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "..." } }
  ]
}
```

Guardrails (client-side):
- Downsample/compress images before sending (keep payloads small)
- Use allowed `media_type` values only (`image/jpeg`, `image/png`, `image/gif`, `image/webp`)
- Respect the proxy’s base64 payload size cap (currently ~20MB; proxy rejects oversized requests)

Provider caveats:
- `perplexity` does not support vision (proxy returns `400`)
- `anthropic` accepts vision but requires base64 image sources (proxy rejects URL images)
- `openai` supports vision; base64 is supported and recommended for alpha

## Testing checklist (minimum)

### Manual flows

- Fresh install → gate shows → paste key → validate → stream list appears.
- Invalid key → gate shows error and blocks.
- Key bound elsewhere → gate shows actionable message.
- Revoke key (server-side) → next validate or AI call blocks and returns to gate.
- AI request (streaming):
  - chunks appear
  - quota errors show correct reset timing
  - request id is visible/copiable on error
- Help tab feedback:
  - submit bug/feature
  - upload attachment via presigned PUT
  - complete endpoint success
  - user sees `feedback_id`
- Diagnostics toggle off → no diagnostic calls.

### Automated tests (suggested)

- Web unit tests for gate state rendering and “submit feedback” happy path (mock bridge).
- Swift unit tests for SSE parser (delta/done/error, CRLF).

## Documentation hygiene (optional; ask before changing)

Some docs in this repo still describe “user API keys” as the configuration gate. Once proxy integration is landed, consider updating:

- `Ticker/docs/PROXY_ARCHITECTURE.md` (to clarify device key registration UX)
- `Ticker/docs/GITHUB_BACKLOG_ALPHA.md` (add explicit D-slice integration checklists)

Ask before making broad doc edits; for now this file is the integration source of truth.
