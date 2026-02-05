# Privacy & Diagnostics (Alpha)

This document defines what Ticker collects and what it does **not** collect.

## Principles

- Default diagnostics **ON**, with clear disclosure and an in-app **opt-out** toggle.
- Collect only what is necessary to debug reliability issues and manage cost.
- Avoid collecting note/editor content by default.
- Web UI should not emit console logs in prod/bundled builds; gate ad-hoc logs behind `import.meta.env.DEV` (see `Web/src/utils/debug.ts`).

## Data collected (by default)

### Proxy request metadata
- Request IDs (`X-Ticker-Request-Id`, treated as an opaque string; Ticker should send a UUID per request)
- Provider/model identifiers
- Token counts (in/out)
- Timing, status code, error codes
- App version, OS version
- Support ID (derived; not the raw key)

### Local-only secrets (stored on device)
- Proxy device key + device id are stored locally at `~/Library/Application Support/Ticker/device.json`.
  - This file contains the **plaintext device key** (`tk_...`) and must be treated as sensitive.
  - The device key is used only to authenticate to the proxy (sent in `Authorization: Bearer ...`).
  - The device key must never be logged, and must never be included in support bundles.

### Diagnostics events
- Structured error events (stack traces where available)
- Key validation failures
- Quota errors

### Crash markers
- Crash summaries/markers sufficient to identify that a crash occurred and where

### Feedback submissions
- Bug reports and feature requests submitted by the user
- Optional screenshot attachment (may contain user content; warn user)

## Data NOT collected (by default)

- Full note corpus / full editor content
- Clipboard contents
- System-wide selection text captured via Accessibility
- Quick Panel “ask” (ephemeral chat) history is not persisted to disk
- Raw AI prompts/responses beyond what is required to fulfill the request (prefer redaction/minimization where practical)

## Retention

- Raw logs/events: **max 30 days**
- Aggregated usage: longer (cost/budgeting)
- Feedback items: longer-term (recommend 6–12 months)
- Attachments: recommend 30–90 days

## User controls

- Settings toggle to disable diagnostics (opt-out).
- Support bundle copying should never include raw device keys or note content.

## Clarification: ephemeral chat vs saved notes

- Quick Panel `⌥↵` “ask” mode is designed to be **in-memory only** and is not written into `ticker.db`.
- Like any AI request, the text still has to be sent to the configured LLM provider (proxy/vendor) to receive a response.
