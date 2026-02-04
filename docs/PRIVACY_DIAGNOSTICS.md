# Privacy & Diagnostics (Alpha)

This document defines what Ticker collects and what it does **not** collect.

## Principles

- Default diagnostics **ON**, with clear disclosure and an in-app **opt-out** toggle.
- Collect only what is necessary to debug reliability issues and manage cost.
- Avoid collecting note/editor content by default.

## Data collected (by default)

### Proxy request metadata
- Request IDs (`X-Ticker-Request-Id`, treated as an opaque string; Ticker should send a UUID per request)
- Provider/model identifiers
- Token counts (in/out)
- Timing, status code, error codes
- App version, OS version
- Support ID (derived; not the raw key)

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
- Raw AI prompts/responses beyond what is required to fulfill the request (prefer redaction/minimization where practical)

## Retention

- Raw logs/events: **max 30 days**
- Aggregated usage: longer (cost/budgeting)
- Feedback items: longer-term (recommend 6–12 months)
- Attachments: recommend 30–90 days

## User controls

- Settings toggle to disable diagnostics (opt-out).
- Support bundle copying should never include raw device keys or note content.
