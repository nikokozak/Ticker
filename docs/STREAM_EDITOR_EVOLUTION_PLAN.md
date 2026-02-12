# Stream Editor Evolution Plan (Ticker-Next)

Ticker-Next is a fork of Ticker focused on evolving the stream editor UX without destabilizing the app shell.

## Scope Decision

Ticker-Next keeps Ticker's proven application structure and iterates on the editor inside a stream.

What stays as-is:
- Main app/window model (menu bar behavior, existing window structure, stream directory/listing flow).
- Settings/help/support access model.
- Existing persistence model (`stream` + `cell`) in this phase.
- WKWebView + React + TipTap architecture.

What changes:
- The editor inside an individual stream.
- Editor interaction quality, visual hierarchy, and writing ergonomics.

Out of scope for this plan:
- Native editor migration (AppKit/TextKit rewrite).
- Replacing WKWebView.
- Replacing stream/cell storage model in this phase.
- App-level navigation/window redesign.

## Product Goals

1. Preserve Ticker's stable app shell and flows.
2. Make stream editing feel faster, clearer, and less noisy.
3. Improve selection-based AI workflows without mode confusion.
4. Preserve stable persistence and bridge contracts while iterating editor UX.

## UX Contracts (Non-Negotiable)

1. Stream list/default page remains primary launch surface.
2. Opening a stream keeps current navigation expectations (title, back/list transitions, settings access where currently provided).
3. Editor changes must not remove or break existing app windows/hotkeys.
4. One coherent editing model per stream (no competing paradigms active at once).

## Technical Direction

Editor platform remains:
- `WKWebView` host in Swift (`Sources/Ticker/App/WebViewManager.swift`)
- React/TipTap editor in `Web/`

Primary target files (expected hot spots):
- `Web/src/components/UnifiedStreamEditor.tsx`
- `Web/src/components/StreamEditor.tsx` (fallback/compat path)
- `Web/src/extensions/*` (cell behavior, keymap, clipboard)
- `Web/src/store/blockStore.ts`
- Bridge/persistence touchpoints only when required by editor behavior

## Delivery Strategy

### Phase E0 — Baseline and Guardrails

- Freeze app-shell scope: no main-window/nav redesign work in editor slices.
- Record current editor baseline with concrete repro notes.
- Use a standard editor smoke checklist for every slice.

### Phase E1 — Layout and Readability

- Improve in-stream readability (spacing, rhythm, hierarchy).
- Reduce visual clutter around cell chrome and controls.
- Keep stream structure recognizable; do not introduce new global nav elements.

### Phase E2 — Editing Interaction Quality

- Tighten boundary key behaviors (Enter/Backspace/Arrow).
- Improve drag/reorder affordances without accidental edits.
- Ensure cross-cell copy/paste remains stable and UUID-safe.

### Phase E3 — AI Interaction Clarity

- Preserve selection-first AI operations:
  - Send
  - Send with Prompt
  - Proofread
  - Summarize
- Guarantee single-undo behavior to pre-AI state.
- Keep AI provenance styling informative only (never semantic).

### Phase E4 — Stability and Regression Hardening

- Validate no regressions in stream load/save/reorder.
- Validate bridge message compatibility for modified editor flows.
- Keep QA focused on editor-in-stream behavior, not app-shell redesign.

## Definition of Done (Editor Slice)

A slice is done only if:
1. App-level flow is unchanged.
2. Stream editor UX improves a specific, documented pain point.
3. No data integrity regressions in stream/cell persistence.
4. AI selection actions and undo semantics pass smoke checks.
5. Build and checks pass (`./tickerctl.sh build-dev`, relevant targeted checks).

## Change Control Rules

Before implementation:
- Restate requested editor behavior and expected user-visible outcome.
- Explicitly call out bridge/persistence impact.

During implementation:
- Small, verifiable slices only.
- No opportunistic app-shell refactors.

If ambiguity appears:
- Stop and ask the user.

## Immediate Next Step

Use this document as canonical guide for Ticker-Next stream-editor work.
Any native-first/editor-replatform references are deprecated for this track.
