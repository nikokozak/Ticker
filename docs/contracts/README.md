# Contracts Notes

## Current Files

- `bridge.v1.json`: historical bridge payload snapshot from the legacy cell-oriented editor implementation. It is retained for reference only.
- `bridge.v2.json`: complete live Swift-to-web bridge payload contract for the CodeMirror stream-document editor.
- `ticker-proxy.openapi.v1.yaml`: proxy API contract.

## Direction

Per `docs/TICKER_NEXT_MVP_PLAN.md`, Ticker-Next is moving to a no-cell stream-document editor model.

Implication:
- `bridge.v1.json` is historical and must not be used for live validation.
- New editor work should define stream-document oriented bridge messages and contracts in `bridge.v2.json`.
- Contract validation checks `bridge.v2.json` only.

When in doubt, confirm contract direction with the user before modifying bridge payload shapes.
