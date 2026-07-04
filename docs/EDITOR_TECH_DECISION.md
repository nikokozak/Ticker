# Editor Technology Decision (Ticker-Next)

Last updated: 2026-02-13

## Purpose

Define the stream editor platform for Ticker-Next under the current constraints:
- no cells
- no native editor
- preserve Ticker shell flow
- iA Writer-style writing experience
- first-class images + PDF highlight linking

## What We Are Emulating from iA Writer

Public iA Writer docs consistently emphasize:
- plain-text Markdown writing
- low-chrome focused editor behavior
- autosave while writing
- image insertion via Markdown or drag/drop workflows

Important note:
- iA Writer's exact internal editor engine is not publicly documented in official materials.
- We should emulate behavior and UX principles, not attempt stack parity.

## Options Evaluated

### Option A: CodeMirror 6 (Recommended)

Strengths:
- built for document editing with precise control over selection/history/transactions
- strong Markdown support via `@codemirror/lang-markdown`
- extension model fits AI annotations, link decorations, and contextual UI actions
- straightforward to keep a calm, iA-style UI without block chrome

Risks:
- requires migration from current ProseMirror/TipTap-specific plugin code
- custom markdown semantics (assets, PDF link anchors) require explicit extension work

### Option B: Lexical

Strengths:
- modern, fast, extensible framework
- solid editor state model and plugin ecosystem

Risks:
- more effort to tune toward strict Markdown-first authoring
- migration still substantial, with less direct Markdown-centric ergonomics than CodeMirror

### Option C: Keep TipTap

Strengths:
- least short-term migration friction from current code

Risks:
- keeps us coupled to cell-era abstractions and schema complexity
- Markdown pipeline is still documented as early/beta in parts of Tiptap docs
- higher risk of drifting back to block/cell behaviors we are intentionally removing

## Decision

Adopt **CodeMirror 6** as the primary stream editor platform in WKWebView.

Implementation implications:
- replace cell editor state with a single stream document state
- persist canonical Markdown document content per stream
- represent AI operations and PDF references as range/anchor metadata, not cell metadata

## PDF Focus and Native Affordances

Use PDFKit in the Swift host for reading/highlighting and bridge actions to the web editor.

Required behavior:
- user highlights text in PDF reader
- app creates a stable highlight identifier
- editor inserts a link/reference to that highlight
- clicking the link navigates back to the exact highlight in PDF

PDFKit supports annotations/markup and document selections; we should use those primitives for durable highlight anchors.

## References

- iA Writer focus/editor behavior:
  - https://ia.net/writer
  - https://ia.net/writer/how-to/write-with-focus
  - https://ia.net/writer/support/editor/focus-mode
  - https://ia.net/writer/support/basics/features
- CodeMirror:
  - https://codemirror.net/
  - https://github.com/codemirror/lang-markdown
- Lexical:
  - https://lexical.dev/
- Tiptap Markdown docs (for risk context):
  - https://tiptap.dev/docs/editor/markdown
  - https://tiptap.dev/docs/editor/markdown/getting-started
- Apple PDFKit:
  - https://developer.apple.com/documentation/pdfkit/pdfannotation
  - https://developer.apple.com/documentation/pdfkit/search-operations
