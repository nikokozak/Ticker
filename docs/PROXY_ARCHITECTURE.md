# Ticker Proxy (Phoenix on Fly.io)

Ticker Proxy enables shipping the app without embedding provider API keys and provides metering, quotas, diagnostics, and support tooling.

## Goals (alpha)

- App uses **Ticker-native API** (provider-agnostic).
- Proxy uses **developer-owned provider keys** (OpenAI/Anthropic/Perplexity/etc).
- **Per-device key** authentication and enforcement.
- Metering and quotas (per-minute + daily + monthly).
- Strong request correlation (`X-Ticker-Request-Id`).
- Diagnostics and feedback ingestion (no note content).
- Raw logs retained for **max 30 days**.

## Non-goals (alpha)

- Payments/billing
- Self-serve signup (waitlist + manual key issuance only)
- Automatic GitHub issue creation (manual promotion only)

## Authentication model (per-device key)

- Each device receives a key (e.g., `tk_live_...`).
- App generates a `device_id` (UUID) and stores it in Keychain.
- First successful request binds the key to `device_id`.
- Subsequent requests with a different `device_id` are rejected with `401`.

This provides lightweight abuse detection and prevents casual key sharing.

## Contract source of truth

- This document is the **human-readable overview** of the proxy behavior and endpoints.
- The **machine-readable API contract** (OpenAPI/JSON schema) should live in the `ticker-proxy` repo (e.g., `openapi/v1.yaml`) and be treated as the source of truth for request/response shapes.
- This repo (`Ticker`) should vendor a **pinned copy** of that contract for client development + snapshot tests, and update it only when the proxy contract changes.
- Versioning is URL-based (`/v1/...`); prefer “proxy first, backwards compatible” changes when evolving endpoints during alpha.

Client integration reference:
- `docs/GITHUB_BACKLOG_ALPHA.md` (Epic D integration notes + acceptance criteria)

## Contract: headers

Requests must include:
- `Authorization: Bearer <device_key>`
- `X-Ticker-Device-Id: <uuid>`
- `X-Ticker-App-Version: <YYYY.MM.patch>`
- `X-Ticker-Platform: macOS`
- `X-Ticker-OS-Version: <version>`

Responses must include:
- `X-Ticker-Request-Id: <string>` (opaque request correlation id)

Notes:
- Ticker should generate a UUID per request and send it as `X-Ticker-Request-Id`.
- The proxy will echo/return `X-Ticker-Request-Id` for every response (including errors). Treat it as an opaque string (not guaranteed to be a UUID).

## Endpoints (v1)

### Validate key
`POST /v1/auth/validate`
- Returns: key status, bound device id, current limits, usage summary

### LLM request
`POST /v1/llm/request`
- Body includes:
  - provider (optional; supported values: `openai`, `anthropic`, `perplexity`)
  - model
  - messages (each `content` is either a string or an array of parts for multimodal prompts)
    - For alpha vision: send **base64** image parts (`media_type` + `data`) rather than URL images
  - streaming flag (`stream: true` uses SSE)
  - metadata (stream id, cell id) *only if non-sensitive*
- Returns:
  - streaming or non-stream response
  - token counts (if available)
  - `X-Ticker-Request-Id`

Notes:
- `perplexity` does not support vision/image inputs (proxy returns `400` for image parts)
- `anthropic` vision requires base64 image sources (proxy rejects URL images)

### Diagnostics
`POST /v1/diagnostics/event`
`POST /v1/diagnostics/crash`
- Structured JSON only; avoid raw editor content.

### Feedback
`POST /v1/feedback`
- `type`: `bug` | `feature`
- `title`, `description`
- Optional attachments (e.g., screenshot) via a presigned upload flow (size-limited; 10MB cap)
- Returns `feedback_id` for the user to reference

## Metering and quotas

Defaults (configurable per key):
- 20 req/min
- 100k daily tokens
- 1M monthly tokens

Behavior:
- `429` when exceeded, with reset timing
- `401` for invalid/unbound-elsewhere keys

## Storage and retention

- Raw logs/events: max 30 days (automated purge job)
- Aggregated usage: longer-term storage for budgeting/history
- Feedback:
  - Keep longer than logs (recommend 6–12 months)
  - Attachments retention can be shorter (recommend 30–90 days)

## Admin (minimum viable)

- Waitlist list + approval
- Issue/revoke device keys
- Adjust quotas per key
- View recent requests/errors per key
- View feedback items and manually promote to GitHub Issues
