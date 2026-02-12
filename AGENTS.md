# Agent Notes (Ticker-Next)

Ticker-Next is an independent fork workspace.

## Scope Boundary (Critical)

- Only modify files under `/Users/niko/Developer/Ticker/Ticker-Next`.
- Do not modify `/Users/niko/Developer/Ticker/Ticker` unless the user explicitly asks in that turn.
- Treat `Ticker-Next` and `Ticker` as separate repos with separate decision histories.

## Canonical Direction

Primary guide for implementation:
- `docs/STREAM_EDITOR_EVOLUTION_PLAN.md`

If any older docs conflict with this plan, follow `docs/STREAM_EDITOR_EVOLUTION_PLAN.md`.
If ambiguity remains, ask the user before implementing.

## Product Focus (Current)

Focus exclusively on the stream editor inside an individual stream.

Must preserve as-is unless explicitly requested:
- app/window structure
- stream directory/listing flow
- settings/help surfaces
- global hotkeys and non-editor windows

## Technical Constraints

- Keep existing architecture: Swift host + WKWebView + React/TipTap.
- Do not initiate native-editor migration work in this repo.
- Avoid persistence/schema rewrites unless required for a specific approved editor behavior.

## Working Rules

- Work in small, verifiable slices.
- Before each slice, restate intended user-visible behavior change.
- Call out bridge/persistence blast radius before editing those layers.
- Stop and ask the user when intent is unclear.

## Branch / Commit Discipline

- Use branches prefixed `codex/`.
- Keep commits scoped to a single logical change.
- Include validation notes in commit messages when useful.
- Do not bundle unrelated refactors.

## Verification Baseline

For editor slices, validate at minimum:
- open stream
- edit content
- copy/paste
- AI action + undo
- save/reload persistence

Suggested commands:
- `./tickerctl.sh build-dev`
- targeted checks relevant to the modified area

## Repo Orientation

- Swift host/app code: `Sources/Ticker/`
- Web editor/UI: `Web/`
- Docs/contracts: `docs/`
