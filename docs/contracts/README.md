# Contracts Notes

## Current Files

- `bridge.v1.json`: historical/current bridge payload snapshot from the legacy cell-oriented editor implementation.
- `ticker-proxy.openapi.v1.yaml`: proxy API contract.

## Direction

Per `docs/TICKER_NEXT_MVP_PLAN.md`, Ticker-Next is moving to a no-cell stream-document editor model.

Implication:
- `bridge.v1.json` should be treated as a migration baseline, not the target end-state.
- New editor work should define stream-document oriented bridge messages and contracts in a follow-on v2 contract file.

When in doubt, confirm contract direction with the user before modifying bridge payload shapes.
