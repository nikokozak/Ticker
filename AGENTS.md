# Agent Notes (Ticker-Next)

Ticker-Next is an independent fork workspace.

## Scope Boundary (Critical)

- Only modify files under `/Users/niko/Developer/Ticker/Ticker-Next`.
- Do not modify `/Users/niko/Developer/Ticker/Ticker` unless the user explicitly asks in that turn.
- Treat `Ticker-Next` and `Ticker` as separate repos with separate decision histories.

## Canonical Direction

Primary guide for implementation:
- `docs/TICKER_NEXT_MVP_PLAN.md`
- `docs/EDITOR_TECH_DECISION.md`

If any older docs conflict with these docs, follow the MVP plan and editor tech decision docs.
If ambiguity remains, ask the user before implementing.

For aesthetic and flow parity decisions:
- Inspect `/Users/niko/Developer/Ticker/Ticker` as a read-only reference for proven interaction patterns.
- Do not edit files in `/Users/niko/Developer/Ticker/Ticker` during this work.
- When parity tradeoffs are unclear, ask the user before choosing a direction.

## Product Focus (Current)

Focus exclusively on the stream editor experience inside an individual stream, while preserving Ticker shell UX.

## Terminology (Required)

- In Ticker-Next discussion, `window` and `page` are interchangeable when referring to sections inside the main app window.
- The main app window includes:
  - default stream-list page/window
  - settings page/window
  - editor page/window
- Inside the editor page/window:
  - the top header/menu is the chrome area (back button, stream title, actions)
  - everything below that header is the editor surface
- Do not reinterpret this vocabulary unless the user explicitly changes it.

Must preserve as-is unless explicitly requested:
- app/window structure
- stream list as default page
- settings/help/support entry points from list context
- global hotkeys and non-editor windows
- stream header conventions (title, back, delete)

Editor guardrails (strict):
- No cells in the new editor UX or primary data contract.
- No persistent split-pane editor layouts that shrink writing width.
- No native editor migration work.
- Target iA Writer-style calm document writing experience.
- Prefer overlays/drawers/modals for utilities, never always-on side chrome.

## Technical Constraints

- Editor remains web-based in WKWebView. Do not build or propose native TextKit/AppKit editor paths.
- Architecture changes are allowed when they support the no-cell stream-document direction.
- Preferred editor foundation for this track: CodeMirror 6 (Markdown-first).
- Treat TipTap/cell-centric editor code as legacy migration surface, not target architecture.
- Do not initiate filesystem-first note model migration in this repo unless explicitly requested.

## Working Rules

- Work in small, verifiable slices.
- Before each slice, restate intended user-visible behavior change.
- Call out bridge/persistence blast radius before editing those layers.
- Actively inspect `/Users/niko/Developer/Ticker/Ticker` as a read-only UX/aesthetic reference when flow or styling decisions are uncertain.
- Stop and ask the user when intent is unclear, especially for shell flow, editor semantics, or migration tradeoffs.

## Branch / Commit Discipline

- Use branches prefixed `codex/`.
- Keep commits scoped to a single logical change.
- Include validation notes in commit messages when useful.
- Do not bundle unrelated refactors.

## Git Command Note (Codex Environment)

- In some Codex sessions, `git fetch` / `git push` may be blocked by command policy.
- If that happens, use:
  - `git ls-remote <remote>` to inspect remote refs
  - `git send-pack <remote-url> <src>:<dst>` to publish branches
- Keep `upstream` read-only (`pushurl` set to `no_push`) and push only to `origin` (`Ticker-Next`).

## Verification Baseline

For editor slices, validate at minimum:
- open stream
- edit content
- copy/paste
- AI `Send` and `Send & Prompt` + undo
- save/reload persistence
- image insert/paste/drop and reload
- PDF open/highlight/link round-trip when touched

Suggested commands:
- `./tickerctl.sh build-dev`
- targeted checks relevant to the modified area

## Repo Orientation

- Swift host/app code: `Sources/Ticker/`
- Web editor/UI: `Web/`
- Docs/contracts: `docs/`
