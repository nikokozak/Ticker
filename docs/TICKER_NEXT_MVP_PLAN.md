# Ticker-Next MVP Plan

Last updated: 2026-02-13

This is the canonical product + implementation direction for Ticker-Next.
If any doc conflicts with this one, this file wins.
Companion implementation rationale lives in `docs/EDITOR_TECH_DECISION.md`.

## 1) Scope and Intent

Ticker-Next is a focused fork of Ticker that modernizes the **stream editor** while preserving Ticker's proven app shell.

What stays:
- stream list as the default page
- settings/help/support access from the list context
- stream page header patterns (title, back, delete)
- existing non-editor windows and hotkeys unless explicitly changed

What changes:
- replace the current cell-centric editor model with a simpler, single-document writing model
- target an iA Writer style writing experience: calm, centered, low chrome, predictable editing

## 2) Non-Negotiable Product Constraints

1. No cell model in the new editor UX or data contract.
2. No native editor.
3. Keep Swift host + WKWebView architecture for the editor surface.
4. No persistent split-pane editor layout that shrinks the writing canvas.
5. Editor must autosave continuously.
6. Image support is required.
7. PDF support is required:
   - in-app PDF reading using Apple PDF affordances
   - highlight support
   - ability to link highlights to locations in stream content

## 3) Editor UX Target (iA-style)

The stream editor must behave like a normal document editor:
- direct typing with no block/cell chrome
- clean text flow with strong typography and spacing rhythm
- selection/copy/paste behavior that feels native and unsurprising
- predictable undo/redo
- minimal always-on controls; contextual actions only

Design guardrails:
- writing area remains visually dominant
- side tools open as drawers/overlays/modals (not persistent split panes)
- no "navigator + cramped editor" layout

## 4) Editor Platform Decision

Decision: move from TipTap/cell-oriented editing to a Markdown-first web editor based on **CodeMirror 6**.

Rationale:
- better fit for plain-document writing than a block/cell abstraction
- robust extension system for AI ranges, inline annotations, and link affordances
- strong control over keyboard, selection, history, and transaction boundaries
- straightforward path for iA-style presentation with minimal UI chrome

Alternatives considered:
- Lexical: strong framework, but more opinionated around rich-node editor patterns than needed for this MVP.
- ProseMirror (direct): flexible, but still pulls us toward schema/node complexity we are intentionally reducing.

Explicitly rejected for this track:
- continuing TipTap as the primary stream editor foundation
- any native TextKit/AppKit editor rewrite

## 5) Data and Bridge Direction

Replace cell-oriented editor persistence for stream writing with a single stream document contract.

Target persisted shape:
- `stream_documents`
- one primary document per stream
- canonical content stored as Markdown (with stable revision metadata)

Migration direction:
- legacy cell content is converted into a single stream document for each stream
- migration is one-way for Ticker-Next
- once migrated, editor behavior no longer depends on per-cell semantics

Bridge direction:
- prefer stream/document events over cell events for active editor operations
- AI operations and annotations attach to ranges/anchors in the stream document

## 6) AI Behavior Contract

Required user-facing actions:
- `Send`
- `Send & Prompt` (opens prompt window; selected content is sent as context)

Behavior rules:
- AI is an edit operation in the current document, not a separate mode
- AI apply is undoable in a single step back to pre-AI state
- selection-first behavior is default; falls back to current paragraph/document only when no selection exists and action allows it
- provenance styling is optional metadata and must not alter edit semantics

## 7) Autosave Contract

- autosave is always on for stream documents
- save triggers on content changes with short debounce
- stream reopen restores latest state accurately
- no manual save affordance required for normal flow

## 8) Image Support Contract

Required:
- paste/drop/insert images into stream content
- local asset persistence and reliable reload
- predictable rendering in editor and exported views

Preferred content representation:
- Markdown image syntax with internal asset URI resolution

## 9) PDF Reader + Highlight Linking Contract

PDF is a first-class companion surface, not an afterthought.

Required:
- open PDFs in-app using native Apple PDF capabilities (PDFKit in host app)
- create/select highlights in the PDF reader
- insert links/references from highlights into stream content
- follow links from stream content back to the exact highlight location in the PDF

Linking model:
- each highlight has a stable ID and source reference
- stream document stores explicit links to those highlight IDs
- navigation is bidirectional: editor -> PDF highlight and PDF highlight -> editor anchor

## 10) Delivery Phases

### E0 - Baseline Parity Lock
- preserve Ticker shell flow and window behavior
- confirm build/run parity and no shell regressions

### E1 - Editor Foundation Reset
- introduce CodeMirror 6 stream editor
- remove cell-based editing UI from active stream editor
- establish single-document persistence path

### E2 - Writing UX Quality
- typography, spacing, and focus behavior tuned for iA-style writing
- keyboard/selection/clipboard quality pass
- no persistent split panes

### E3 - AI Operations
- implement `Send` and `Send & Prompt` in the new document model
- enforce one-undo AI apply behavior
- maintain autosave integrity through AI operations

### E4 - Images
- complete image insert/paste/drop pipeline
- ensure durable persistence + reload

### E5 - PDF Linking
- in-app PDF reader + highlighting
- bidirectional links between highlights and editor anchors

### E6 - Stability Hardening
- regression sweep across load/save, undo/redo, AI flows, images, PDF links
- performance and crash hardening for alpha usage

## 11) Definition of Done (Per Slice)

A slice is complete only if:
1. app-shell flow remains aligned with Ticker
2. editor moves toward the no-cell iA-style target
3. autosave/reload integrity passes
4. AI send flows behave per contract
5. touched-area build/tests/manual checks pass

## 12) Execution Rules

- ship in small, verifiable slices
- restate user-visible behavior before each implementation slice
- call out persistence/bridge blast radius before touching those layers
- when UX tradeoffs are unclear, ask the user before choosing
