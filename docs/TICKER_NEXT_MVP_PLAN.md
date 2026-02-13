# Ticker Next MVP Plan

## Purpose

This document is the canonical product direction for Ticker-Next.

Ticker-Next is **not** a full app-shell rewrite. It is an editor-focused evolution of Ticker:
- keep Ticker’s proven app flow and UX scaffolding
- make the in-stream editor feel like a normal, coherent document editor
- remove cell-driven UX noise without destabilizing the rest of the app

## Non-Negotiable UX Contracts

1. Keep the existing app shell and flow intact:
   - default page is the stream list
   - settings/help/support access remains where users expect it
   - stream view keeps title, back navigation, and delete controls
   - existing non-editor windows/hotkeys continue to work
2. Do not introduce persistent split panes that shrink writing width.
   - utilities (outline, sources, metadata) must be overlay/drawer/modal based
3. Preserve Ticker’s visual language and interaction familiarity outside the editor.
   - this is an adjustment, not a product reinvention

## Editor Direction (MVP)

### Target Experience

- The editor should feel like a normal text document:
  - direct typing
  - unsurprising selection/copy/paste
  - predictable undo/redo
  - clear typographic hierarchy and spacing rhythm
- “Cells” may still exist as an implementation/persistence detail during migration, but **must not dominate the user experience**.
- No mandatory block chrome during normal writing. Controls appear contextually and remain low-noise.

### AI Interaction Contract

- AI is an edit operation, not a mode switch.
- Selection-first actions include:
  - Send
  - Send & Prompt
  - Proofread
  - Summarize
- Applying AI changes must support a single undo back to pre-AI state.
- AI provenance styling is informative only and never changes editing semantics.

### Save/Persistence Contract

- Editor autosaves continuously.
- Reloading a stream restores latest content accurately.
- No regressions in stream load/save/reorder/data integrity.

## Technical Direction (Agreed Track)

### Keep

- Existing architecture for this phase:
  - Swift host app
  - WKWebView
  - React/TipTap editor stack
- Existing stream/cell persistence model for compatibility while editor UX is being improved.

### Do Not Do (in this track)

- No native-first editor rewrite (no AppKit/TextKit migration for editor).
- No replacement of WKWebView.
- No app-level navigation/window model rewrite.
- No filesystem-first note migration as part of this MVP track.

## Delivery Phases

### E0 — Guardrails + Baseline

- Lock app-shell scope.
- Confirm stream list/settings/help/stream header parity.
- Establish smoke checks for editor regressions.

### E1 — Readability + Layout

- Widen and relax writing surface.
- Reduce cell chrome prominence.
- Keep utility panels non-blocking (overlay/drawer).

### E2 — Interaction Quality

- Tight keyboard boundary behavior.
- Reliable copy/paste and selection flows.
- Stable drag/reorder behavior with no accidental edits.

### E3 — AI Clarity

- Ensure Send and Send & Prompt behavior is explicit and predictable.
- Keep proofread/summarize selection workflows fast and reversible.
- Maintain one-undo semantics.

### E4 — Stability Hardening

- Regression pass: save/reload, undo/redo, reorder, AI actions.
- Confirm no app-shell behavior regressions from editor work.

## Definition of Done (Per Slice)

A slice is complete only if:

1. App shell behavior is unchanged.
2. Editor behavior moves toward the normal-document target.
3. Autosave/reload integrity holds.
4. AI actions + undo contract holds.
5. Build/test checks for touched areas pass.

## Working Protocol

- Make small, verifiable slices.
- Before each slice, restate user-visible behavior change.
- Call out bridge/persistence blast radius before editing those layers.
- If there is ambiguity about UX direction, ask the user before implementing.
