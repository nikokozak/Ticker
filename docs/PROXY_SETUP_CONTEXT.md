# Proxy Setup Context (Ticker Proxy)

This file captures the current plan/spec for building `ticker-proxy` (Phoenix/Elixir on Fly.io). It’s written to be “LLM-friendly”: small, well-scoped slices with explicit acceptance criteria.

## Status (current reality)

Ticker Proxy is now implemented (C1–C11) in the separate `Ticker-Proxy/` repo, including:
- Device keys (issuance/revoke/quotas) + binding enforcement
- Req/min rate limiting + daily/monthly token budgets
- LLM proxy with multi-provider routing + SSE streaming
- Diagnostics + feedback (with attachments via presigned uploads)
- Request logs + admin viewers + retention jobs

For current contract details:
- Machine-readable: `Ticker-Proxy/openapi/v1.yaml`
- Ticker-side integration plan: `docs/GITHUB_BACKLOG_ALPHA.md` (Epic D + D8)

This document remains as historical context but is updated where it impacts client integration (headers, IDs, and high-level invariants).

## Canonical References (in this repo)

- `docs/PROXY_ARCHITECTURE.md` — product-level goals + endpoint list (human-readable)
- `docs/GITHUB_BACKLOG_ALPHA.md` — Epic C issue list + acceptance criteria
- `docs/PRIVACY_DIAGNOSTICS.md` — what we collect (and don’t), retention expectations
- `docs/TEST_STRATEGY.md` — proxy contract/snapshot test expectations

## High-Level Decisions (locked unless explicitly changed)

### Repo strategy

**Separate repo** for the proxy server, as a sibling to Ticker:

```
/Users/niko/Developer/
├── Ticker/           # macOS app (Swift + React)
└── ticker-proxy/     # Phoenix/Elixir on Fly.io + Fly Postgres
```

Why: different language/tooling, different deployment lifecycle, and the proxy holds secrets/keys (security boundary).

### Runtime + hosting

- Phoenix (Elixir)
- Fly.io (TLS, secrets via `fly secrets`)
- Fly Postgres (primary database)
- Admin UI is **vital** (Phoenix LiveView), not CLI-only

### Alpha scope

- Per-device keys (`tk_live_...`) with first-use binding to `device_id`
- Admin interface for waitlist + issuance + revocation + quotas + basic dashboards/triage
- Rate limiting + token budgets
- Diagnostics + feedback ingestion (no note/editor content by default)
- 30-day retention for raw request logs/diagnostics; longer for aggregated usage; longer for feedback
- Non-goals (alpha): billing, self-serve signup, automatic GitHub issue creation

## API Contract & Coordination (keep coordination cheap)

We need a single “source of truth” for the HTTP contract.

Recommended approach:

1. `ticker-proxy` repo owns the machine-readable contract (`openapi/v1.yaml` or JSON schema).
2. This repo (`Ticker`) vendors a pinned copy (for client dev + snapshot tests) and links to it from `docs/PROXY_ARCHITECTURE.md`.
3. Versioning:
   - URL prefix: `/v1/...`
   - Include a client version header (already planned): `X-Ticker-App-Version`

Compatibility policy (alpha):
- Prefer “proxy first, backwards compatible”, then update Ticker.

## Required Headers (contract invariant)

Requests must include:
- `Authorization: Bearer <device_key>`
- `X-Ticker-Device-Id: <uuid>`
- `X-Ticker-App-Version: <YYYY.MM.patch>`
- `X-Ticker-Platform: macOS`
- `X-Ticker-OS-Version: <version>`

Responses must include:
- `X-Ticker-Request-Id: <string>` (opaque request correlation id; returned for every response, including errors)

Notes:
- Ticker should generate a UUID per request and send it as `X-Ticker-Request-Id`.
- The proxy will echo/return the request id; treat it as an opaque string (not guaranteed to be a UUID).

## Default Quotas (configurable per key)

- 20 requests/minute
- 100k tokens/day
- 1M tokens/month

Proxy returns `429` with reset timing when exceeded.

## Data Minimization (privacy invariant)

From `docs/PRIVACY_DIAGNOSTICS.md`:
- Do not store note/editor content by default.
- Diagnostics events are structured metadata + error context only.
- Feedback attachments may contain user content; warn users and retain for a bounded period.

## Suggested Phoenix Scaffold (supports Admin UI)

Do NOT scaffold as API-only; we need LiveView.

Suggested commands (run in `/Users/niko/Developer`):

```bash
mix phx.new ticker_proxy --binary-id --database postgres
cd ticker_proxy
git init
```

Notes:
- `--binary-id` uses UUIDs (recommended for public-facing IDs).
- Keep HTML/assets because admin is LiveView.

## Fly.io Setup (C1 baseline)

Minimum setup goals:
- Deployed with TLS (Fly default)
- `GET /health` returns 200
- Secrets via `fly secrets set`
- Fly Postgres attached (and migrations runnable in deploy)

Operational expectations:
- A “health check” should not require DB connectivity (separate `/ready` can, if desired).
- Every request has request-id correlation (`X-Ticker-Request-Id`) and structured logging includes it.

## Core Domain Model (initial, can evolve)

This is the “shape of the system” so implementation tasks stay consistent. Table names are suggestions.

### Device keys (per-device auth)

`device_keys`
- `id` (UUID)
- `key_prefix` (e.g. `tk_live_`)
- `key_encrypted` (stored encrypted in DB; raw key never stored in plaintext)
- `support_id` (stable, non-secret identifier shown to users; stored at issuance)
- `email` (string; the invite/waitlist email)
- `device_label` (string; user-provided label like “Work MacBook”)
- `bound_device_id` (UUID nullable; set on first successful request)
- `revoked_at` (timestamp nullable)
- quota overrides (nullable): `reqs_per_min`, `tokens_per_day`, `tokens_per_month`
- timestamps: `inserted_at`, `updated_at`
- optional ops fields: `last_seen_at`, `last_ip` (consider privacy implications before adding)

Key invariants:
- Only `support_id` is ever displayed back to the user/admin list views.
- Key format: `tk_live_` + a cryptographically random secret (displayed once at issuance).
- The raw key is never returned again after issuance, and never stored in the DB in plaintext.
- A revoked key always fails auth.
- If `bound_device_id` is set and differs from `X-Ticker-Device-Id`, return `401` with actionable message.

### Usage + quotas

For alpha, the simplest DB-backed counters are:

`usage_minutes` (for req/min)
- `device_key_id`
- `minute_start` (UTC minute bucket)
- `request_count`

`usage_days` (for token/day)
- `device_key_id`
- `date` (UTC)
- `input_tokens`, `output_tokens`, `total_tokens`

`usage_months` (for token/month)
- `device_key_id`
- `month` (e.g. `2025-12-01` UTC)
- `input_tokens`, `output_tokens`, `total_tokens`

Implementation note:
- Update counters in a transaction after the provider response returns token usage.
- If token usage is unknown (provider doesn’t report), define an explicit policy (e.g. “count 0 and log”, or “estimate and log”).

### Request log (for triage; 30-day retention)

`request_logs`
- `id` (UUID)
- `request_id` (string; mirrors `X-Ticker-Request-Id`)
- `device_key_id` (FK)
- `path`, `method`, `status`
- `provider`, `model`
- `duration_ms`
- `error_code` (nullable)
- timestamps

Retention: purge rows older than 30 days.

### Diagnostics (structured; 30-day retention)

`diagnostic_events`
- `id` (UUID)
- `request_id` (nullable UUID)
- `device_key_id` (nullable FK)
- `type` (string)
- `payload` (JSONB; structured, non-content)
- timestamps

### Feedback (longer retention; attachments optional)

`feedback_items`
- `id` (UUID) and/or a short `feedback_id` suitable for user reference
- `device_key_id` (nullable FK if user submits without a valid key)
- `type` (`bug` | `feature`)
- `title`, `description`
- `metadata` (JSONB; app/os versions, request ids, etc.)
- timestamps

`feedback_attachments`
- `id` (UUID)
- `feedback_item_id` (FK)
- `original_filename`, `content_type`, `byte_size`
- `storage_key` (object-store key; do not store blobs in Postgres)
- timestamps

Attachment storage decision (pick one):
- Fly.io Tigris object storage (recommended if staying “all Fly”)
- S3/R2 (also fine)

## Endpoint Specs (alpha-level; keep stable)

This section is intentionally “tight”: enough detail to implement without debating semantics every time.

### Standard error envelope (recommended)

Keep error shapes stable so the client UX stays simple.

```json
{
  "error": {
    "code": "quota_exceeded",
    "message": "Daily token budget exceeded.",
    "details": {
      "reset_at": "2025-12-22T00:00:00Z"
    }
  }
}
```

Notes:
- Always include `X-Ticker-Request-Id` response header, even on errors.
- Prefer a small, enumerable set of `code` values (e.g. `invalid_key`, `key_revoked`, `key_bound_elsewhere`, `quota_exceeded`, `validation_error`, `upstream_error`).

### `GET /health`
- Returns 200 with a tiny JSON body, no DB required.

### `POST /v1/auth/validate`
Purpose: allow Ticker to validate the device key and fetch limits/usage.

Returns (suggested):
- `support_id`
- `bound_device_id` (nullable)
- `limits`: req/min + tokens/day + tokens/month
- `usage`: current minute count, today tokens, month tokens, reset timestamps

Error cases:
- `401 invalid_key`
- `401 key_revoked`
- `401 key_bound_elsewhere`
- `429 quota_exceeded` (include reset info)

### `POST /v1/llm/request`
Purpose: provider-agnostic request (start with 1 provider).

Alpha implementation guidance:
- Supports multiple providers (`openai`, `anthropic`, `perplexity`) and both non-streaming and SSE streaming responses.

Must:
- Authenticate device key + enforce binding
- Enforce req/min + budgets
- Call provider using operator-owned provider key(s) stored in Fly secrets
- Return `X-Ticker-Request-Id`
- Record metering + request log (no prompt content stored)

### `POST /v1/diagnostics/event` and `POST /v1/diagnostics/crash`
Purpose: structured diagnostics ingestion (no editor content).

Must:
- Accept JSON payloads
- Store structured metadata only
- Retain max 30 days (purge job)

### `POST /v1/feedback`
Purpose: user-submitted bug/feature reports with optional attachment(s).

Must:
- Return a `feedback_id` the user can reference in support
- Enforce size caps
- Allow attachments via a presigned upload flow (Tigris S3-compatible)
Client guidance:
- Support bundle payloads must not include note/editor content or raw device keys.

## Admin UI (LiveView) — minimum viable screens

Prioritize “operational usefulness” over polish.

1. Login (alpha can be a single admin password via Fly secret; upgrade later)
2. Waitlist list + approve (if waitlist is in proxy; otherwise defer and just issue keys)
3. Device keys
   - Issue new key (email + device label)
   - Revoke key
   - View bound device id, last seen, quotas
4. Usage dashboards
   - Per-key usage (day + month), quota override editor
   - Basic “top keys by tokens” and “error rate” (nice-to-have)
5. Feedback inbox
   - List feedback items, view details, download attachments, copy text for GitHub
6. Diagnostics viewer (basic)
   - Recent errors by request id / support id

## Security Checklist (alpha minimum)

- Never log raw `Authorization` tokens (ensure plugs redact headers).
- Never store raw device keys in plaintext (encrypted storage is acceptable for alpha).
- Encrypt provider API keys at rest (best) or keep only in secrets (acceptable for alpha).
- Strict request size limits; attachment size caps.
- Ensure CORS is configured intentionally (or disabled if app-only).

## Implementation Slices (designed for LLM success)

These are intentionally small. Each slice should be a PR with its own tests and a simple verification recipe.

Status note: These proxy slices (C1–C11) are now complete in `Ticker-Proxy/`. Ticker-side integration work is tracked under Epic D and implemented per `docs/PROXY_INTEGRATION.md`.

### Slice C1a — Repo scaffold + local boot
AC:
- `mix test` passes
- App boots locally with `mix phx.server`
- `GET /health` returns 200

### Slice C1b — Fly deploy skeleton (+ Postgres attached)
AC:
- `fly deploy` succeeds
- `GET https://<app>.fly.dev/health` returns 200
- DB is provisioned/attached; migrations runnable

### Slice C2a — Device key issuance (admin-only, no API yet)
AC:
- Admin UI can create a key (email + device label)
- Raw `tk_live_...` displayed once at creation; never stored
- List view shows `support_id`, email, device label, revoked state

### Slice C2b — Revoke + quota override UI
AC:
- Revoke key flips it unusable
- Admin can set per-key quota overrides

### Slice C3 — Auth plug: validate + first-use binding
AC:
- `POST /v1/auth/validate` implemented
- First successful auth binds `bound_device_id`
- Mismatch returns `401 key_bound_elsewhere` with actionable message
- Response includes `X-Ticker-Request-Id` for success and failures

### Slice C5a — Req/min limiter (DB-backed minute buckets)
AC:
- Default 20 req/min enforced per key
- Returns `429` with reset timing

### Slice C4a — LLM request (non-streaming, one provider)
AC:
- `POST /v1/llm/request` works end-to-end for 1 provider
- Token usage recorded and returned
- No prompt/response content stored in DB

### Slice C5b — Token budgets (daily + monthly)
AC:
- Enforces 100k/day and 1M/month (overrideable)
- Returns `429` with reset timing and usage summary

### Slice C6 — Diagnostics ingestion + purge job
AC:
- Event + crash endpoints store structured payload
- Purge job removes raw rows older than 30 days

### Slice C7 — Feedback + attachments + admin inbox
AC:
- `POST /v1/feedback` returns `feedback_id`
- Attachments supported with size cap and storage backend
- Admin UI can view feedback and download attachments

## Known Open Decisions (write down before implementing)

- Attachment storage: decided as Tigris (presigned upload).
- Admin auth: currently a single shared password (acceptable for alpha).
- Streaming protocol: decided as SSE for `/v1/llm/request`.
