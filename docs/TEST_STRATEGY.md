# Test Strategy (Alpha Minimum)

Ticker is a note-taking app with persistence and an AI/proxy integration. For alpha, testing should prioritize preventing:
- data loss,
- protocol breakage (bridge/proxy),
- regressions in the AI request path.

## Required checks on every PR

- Swift build succeeds (`xcodebuild ...`)
- Web typecheck succeeds (`npm run typecheck`)

## Smoke coverage (must-have before inviting users)

1) **Stream CRUD**
   - Create stream
   - Open stream
   - Delete stream

2) **Persistence roundtrip**
   - Edit content, ensure it persists across restart

3) **AI request flow**
   - App → Proxy request
   - Proxy → Provider
   - Response returned and rendered
   - Request correlation ID captured (`X-Ticker-Request-Id`, treated as an opaque string)

4) **Schema snapshot tests**
   - Bridge message payload shapes
   - Proxy request/response JSON shapes

## Guidance

- Prefer “cheap tests that catch breaking changes” over broad end-to-end automation at this stage.
- Snapshot tests are especially valuable for avoiding accidental protocol breakage when iterating quickly.
