# Changelog

All notable user-facing changes to Ticker are documented here.

## Unreleased

### Added
- Live markdown concealment in the stream editor so formatting marks fade away off the active line while styled text remains readable.

### Changed
- TBD

### Fixed
- Recovered quick-capture notes that previously didn't appear in streams.
- Stopped embedded stream images from flickering or refetching while editing nearby text, and made cursor movement skip image tokens atomically.
- Restored the stream editor selection action menu using CodeMirror selection state.
- Made Quick Panel dismissal consistent, stabilized stream picking, and added visible save feedback.

### Removed
- TBD

## Versioning

Ticker uses `YYYY.MM.patch` (alpha), e.g. `2026.01.3`.
