# Ticker-Next Production Readiness Plan

> **For agentic workers (Codex):** Execute tasks strictly in order within a phase. One task = one commit (or one small PR). Before each task, restate the user-visible behavior change in one sentence. After each task, run the listed verification. Do not start a task while the previous task's verification fails. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the capture→document pipeline, delete the dead cell-era subsystem, make markdown rendering and the selection popover reliable, decompose the Swift god object, and harden the bridge — so the app matches its own MVP contract and is shippable to alpha users.

**Architecture:** The app is already what the MVP plan says it should be — a CodeMirror 6 markdown document editor in a WKWebView with a Swift host — but it is wrapped in a dead TipTap/cell subsystem that still owns the Quick Panel write path. The plan converges everything on ONE data model (`stream_documents.markdown`), ONE external-write primitive (`appendToStreamDocument` + `streamDocumentAppended` bridge event), then deletes the corpse and splits the 2,498-line `WebViewManager`.

**Tech Stack:** Swift/AppKit + GRDB (SQLite), WKWebView bridge, React + CodeMirror 6 (`@uiw/react-codemirror`, `@codemirror/lang-markdown`), Vite/TypeScript.

## Global Constraints (from `docs/TICKER_NEXT_MVP_PLAN.md` + `AGENTS.md`)

- No cell model in editor UX or primary data contract.
- No native editor; editor stays CodeMirror 6 in WKWebView.
- No persistent split-pane that shrinks the writing canvas (PDF pane is the sanctioned exception, opened on demand).
- Autosave always on; stream reopen restores latest state.
- AI apply must be undoable in one step.
- Images and PDF-highlight linking are required capabilities.
- Branches prefixed `codex/`; small scoped commits; changelog entry per user-facing change.
- Only modify files under `Ticker-Next/`.
- Verification baseline per editor slice: open stream, edit, copy/paste, AI Send / Send & Prompt + undo, save/reload, image insert/reload, PDF round-trip when touched.

---

## Audit Summary (read this before any task)

Root causes established by a four-way audit (quick panel flow, persistence, web editor, Swift shell), with file:line evidence:

1. **P0 — Quick Panel writes are invisible.** Quick Panel persists to the legacy `cells` table (`PersistenceService.swift:581-608`), while the main editor renders only `stream_documents.markdown` (`StreamEditor.tsx:114`). Nothing folds one into the other. The frontend "live insert" is a no-op: `useBridgeMessages.ts:88` guards on `editorAPI.insertCells`, which `StreamEditor.tsx:180-185` never implements, so cells fall into a Zustand `blockStore` that nothing renders. A capture that *creates* a stream appears only because `loadOrCreateStreamDocument` (`PersistenceService.swift:500-535`) seeds markdown from cells exactly once — and that seed drops images (`htmlToPlainText`, `:888-909`). Every later capture into that stream is silently orphaned, while `streams.updated_at` and `cell_count` still bump (`:292-317`) — the "ghost save" the user sees.
2. **P0 — No external-write consistency mechanism.** The editor holds `markdownContent` in React state and blindly UPSERTs the whole blob every 350ms (`StreamEditor.tsx:240-257`). There is no DB observation and no reload on `quickPanelCellsAdded` for an open stream (`App.tsx:146-170` acts only on `isNewStream`). Any future external write would be clobbered by the next autosave.
3. **P1 — Markup is tinted, not rendered.** The only styling is a Lezer `HighlightStyle` (`StreamEditor.tsx:40-94`); all markdown punctuation stays visible. Images are the sole widget, and `MarkdownImageWidget.ts:166-192` rebuilds the entire decoration set with a whole-document regex scan on every keystroke *and* every scroll (flicker + O(doc) work), with no `atomicRanges` guard.
4. **P1 — Selection popover exists but is fragile.** `StreamEditor.tsx:594-614, 769-807` drives it from `document.selectionchange` + `window.getSelection()` containment checks instead of CodeMirror selection state; in WKWebView this silently yields `null` placement and the menu never shows.
5. **P1 — Dead subsystems still write data.** The whole TipTap cell stack (~15 web files + `@tiptap/*`, `tippy.js`, `marked`, `dompurify`) is unmounted but `useBridgeMessages.ts` still converts AI messages to HTML and persists `saveCell` rows. On the Swift side, `AIService`, `AnthropicService`, `PerplexityService`, and the `LLMProvider` protocol are ~950 dead lines; the RAG stack (Embedding/Retrieval/RAGMigration + semantic search, ~950 lines) is hard-disabled by `proxyOnlyMode` yet still burns CPU chunking every source.
6. **P1 — `WebViewManager.swift` is a 2,498-line god object** whose `processMessage` switch is ~1,250 lines (`:819-2073`). The in-flight PDF branch made it worse by deleting the standalone `PDFReaderWindowController.swift` (203 lines) and inlining ~460 lines of PDF pane + window-geometry code, plus a likely-accidental regression from continuous scroll to `.singlePage` (`WebViewManager.swift:248`).
7. **P2 — Bridge fragility.** Inbound (JS→Swift) messages have no contract and are stringly typed with silent `guard…return` drops; outbound typed payloads (`BridgePayloads.swift`) exist but are bypassed; two correlation conventions (`callbackId` vs payload ids, and `cellId` vs `requestId` for the same concept); `AnyCodable` decodes integral JS numbers as `Int` so `as? Double` casts fail (`BridgeService.swift:31-33`).
8. **P2 — Tests assert the wrong model.** The only persistence tests verify Quick Panel cells land in the `cells` table (`Tests/TickerTests/DeviceKeyServiceTests.swift:108-237`) — they pass while the user-visible feature is broken. `stream_documents` has zero coverage.
9. **P2 — Doc drift.** DB actually lives at `~/Library/Application Support/Ticker-Next/` (`PersistenceService.swift:34-39`) while `docs/DATA_MIGRATIONS.md:8` mandates `.../Ticker/`. `START_HERE.md`'s Quick Panel description documents the pre-migration behavior.

**Sequencing rationale:** Phase 0 stops the in-flight branch from entrenching regressions. Phase 1 fixes the P0 user-facing bug on one unified primitive. Phase 2 deletes the corpse (only safe after Phase 1 removes the last live dependency on cells). Phase 3 delivers the rendering/popover quality the MVP promises. Phase 4 pays structural debt so the codebase stays maintainable. Phase 5 locks it in with tests/CI/docs.

---

## Phase 0 — Stabilize the in-flight PDF branch (`codex/pdf-reader-linking-foundation`)

### Task 0.1: Re-extract the PDF pane into its own controller

**Files:**
- Create: `Sources/Ticker/App/PDFReader/PDFReaderPaneController.swift`
- Modify: `Sources/Ticker/App/WebViewManager.swift` (remove lines ~6-20, ~174-299, ~476-712)
- Modify: `Ticker.xcodeproj/project.pbxproj` (add new file)

**Interfaces:**
- Produces: `final class PDFReaderPaneController: NSViewController` owning `pdfPaneView`, exposing:
  - `func present(url: URL, sourceId: UUID, displayName: String)`
  - `func setVisible(_ visible: Bool)`
  - `var onLinkSelection: ((PDFHighlightLinkPayload) -> Void)?`
  - `var onClose: (() -> Void)?`
- `WebViewManager` keeps only: creating the controller, wiring callbacks, and forwarding `pdfHighlightLinked` over the bridge.

- [ ] Move `PDFHighlightLinkPayload`, `PDFPaneResizeHandleView`, `configurePDFPane`, `presentPDFInPane`, `setPDFPaneVisible`, `maxAllowedPDFPaneWidth`, `growMainWindowForPDFPane`, `shrinkMainWindowAfterClosingPDFPane`, `clampPDFPaneWidth`, `makePDFPaneHeader`, `releaseActivePDFContext`, and the four `@objc` handlers into `PDFReaderPaneController`. Window-growth logic takes the window as a parameter; the controller must not reach into `WebViewManager`.
- [ ] Restore continuous scrolling: `pdfView.displayMode = .singlePageContinuous` (the branch regressed this to `.singlePage` at `WebViewManager.swift:248`; the deleted `PDFReaderWindowController.swift:826` had continuous + `usePageViewController(true)`).
- [ ] Add `default.profraw` to `.gitignore` and delete the stray file.
- [ ] Verify: `./tickerctl.sh build-dev` succeeds; open a PDF source → pane opens, scrolls continuously, "Link Selection" still inserts a link into the stream, closing the pane restores window size.
- [ ] Commit: `refactor: extract PDFReaderPaneController from WebViewManager`

### Task 0.2: Land the branch

- [ ] Run the PDF round-trip verification from AGENTS.md (open/highlight/link/follow-back), plus stream open/edit/save/reload smoke.
- [ ] Merge/PR `codex/pdf-reader-linking-foundation` to `main` with a changelog entry.

---

## Phase 1 — Fix the capture pipeline (the P0 bug)

Design decision (locked): **Option B — Quick Panel writes markdown directly. The `cells` table is no longer written by anything.** One primitive for every external write:

- Swift: `PersistenceService.appendToStreamDocument(streamId:fragment:) -> AppendResult`
- Bridge (Swift→JS): `streamDocumentAppended { streamId, fragment, isNewStream, source }` (add to `docs/contracts/bridge.v2.json`)
- Web: open editor applies the fragment as a CodeMirror transaction; closed streams need nothing (next `loadStream` reads the DB).

### Task 1.1: `appendToStreamDocument` in PersistenceService (TDD)

**Files:**
- Modify: `Sources/Ticker/Services/PersistenceService.swift`
- Test: `Tests/TickerTests/StreamDocumentTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct AppendResult { let fragment: String; let isNewDocument: Bool }
  func appendToStreamDocument(streamId: UUID, fragment: String) throws -> AppendResult
  ```
  Behavior: UPSERT into `stream_documents`; if a row exists, new markdown = `existing + "\n\n" + fragment` (skip separator when existing is empty); bump `stream_documents.updated_at` and `streams.updated_at` in the same transaction.

- [ ] Write failing tests in `StreamDocumentTests.swift` (mirror the temp-DB helper at `DeviceKeyServiceTests.swift:219-237`):
  - append to a stream with no document row creates the row with exactly the fragment;
  - append to an existing document produces `existing + "\n\n" + fragment`;
  - two sequential appends preserve order;
  - `loadOrCreateStreamDocument` after an append returns markdown containing the fragment (this is the regression test for the original bug).
- [ ] Run: `swift test --filter StreamDocumentTests` → FAIL (method missing).
- [ ] Implement; run again → PASS.
- [ ] Commit: `feat(persistence): add appendToStreamDocument primitive`

### Task 1.2: Quick Panel saves markdown, not cells

**Files:**
- Modify: `Sources/Ticker/App/QuickPanel/QuickPanelManager.swift` (`addToStream` `:408-481`, `createContextCell` `:542`, `notifyFrontend` `:604-618`)
- Modify: `docs/contracts/bridge.v2.json` (add `streamDocumentAppended`)
- Modify: `Web/src/types/bridge.ts` (add to `SWIFT_TO_WEB_MESSAGE_TYPES`)

**Interfaces:**
- Produces a markdown fragment builder replacing cell construction:
  - captured selection/clipboard text → blockquote lines (`> …`) followed by an italic attribution line (`*— AppName*`) when a source app is known;
  - captured image → save via `AssetService`, emit `![capture](ticker-asset://<id>)`;
  - user input → plain paragraph after the quote.
- Sends `streamDocumentAppended` with `{ streamId, fragment, isNewStream, source: "quickPanel" }` instead of `quickPanelCellsAdded`.

- [ ] Replace `createContextCell` + `insertQuickPanelCells` usage in `addToStream` with fragment building + `appendToStreamDocument`. Delete the AI-placeholder-cell creation (`:447-467`); AI handling changes in Task 1.4.
- [ ] Keep `streamsChanged` emission for new-stream creation (`:508-511`).
- [ ] Run `node tools/contracts/check_bridge_contract.mjs` → PASS.
- [ ] Verify manually: capture into an existing stream while it is NOT open → reopen stream → captured text and image are present after reload. Capture creating a new stream still works, and the image now survives (fixes the lossy `htmlToPlainText` seed path by bypassing it).
- [ ] Commit: `fix(quickpanel): persist captures to stream_documents via appendToStreamDocument`

### Task 1.3: Open editor applies appends live

**Files:**
- Modify: `Web/src/components/StreamEditor.tsx`
- Modify: `Web/src/App.tsx` (`:146-170` — remove the `quickPanelCellsAdded` handler; keep new-stream `loadStream` behavior keyed off `streamDocumentAppended.isNewStream`)

**Interfaces:**
- Consumes: `streamDocumentAppended` (Task 1.2).
- In `StreamEditor`, a bridge listener (join the existing `bridge.onMessage` subscription at `:259`, do not add a fourth listener) that, when `payload.streamId === stream.id`, dispatches:
  ```ts
  const view = editorViewRef.current; if (!view) return;
  const end = view.state.doc.length;
  const sep = end > 0 ? '\n\n' : '';
  view.dispatch({ changes: { from: end, insert: sep + payload.fragment } });
  ```
  The subsequent 350ms autosave persists the merged doc, which converges with the DB (Swift already appended the same fragment; whole-doc UPSERT makes the echo harmless).

- [ ] Implement the handler; scroll the appended range into view (`EditorView.scrollIntoView(end)`), do not steal focus.
- [ ] Verify: with a stream open in the main window, hit ⌘L, type text, ↵ → text appears at the document end within ~1s; type more in the editor, quit, relaunch → both the capture and the edits persisted.
- [ ] Verify the race: type in the editor *while* capturing → neither the local edit nor the capture is lost.
- [ ] Commit: `fix(editor): apply external document appends as CodeMirror transactions`

### Task 1.4: Quick Panel ⌘↵ (AI + Save) on the document model

**Files:**
- Modify: `Sources/Ticker/App/QuickPanel/QuickPanelManager.swift`

**Interfaces:**
- Consumes: `appendToStreamDocument` (1.1), `streamDocumentAppended` (1.2), existing `AIOrchestrator` (already injected; the ephemeral ⌥↵ path at `handleOptionEnter` shows the streaming pattern).
- Behavior: ⌘↵ = append the capture fragment (as in 1.2), then run the orchestrator with the stream document markdown as context (`loadOrCreateStreamDocument(...).markdown`, not the dead `blockStore` cells), and on completion append the AI response as a second fragment (`source: "quickPanelAI"`). Works whether or not the stream is open; the open editor receives both fragments via Task 1.3.

- [ ] Implement; remove the `triggerAI`/`think` bridge trigger from the old `notifyFrontend` path (`useBridgeMessages.ts:111-156` becomes unreachable — deleted in Phase 2).
- [ ] Verify: ⌘↵ with the target stream open → capture appears, then AI response streams in as an appended block; with the stream closed → open it afterwards, both are there. Context check: the AI answer demonstrably reflects existing stream content.
- [ ] Commit: `feat(quickpanel): document-model AI+Save`

### Task 1.5: Recover orphaned captures (one-time migration)

**Files:**
- Modify: `Sources/Ticker/Services/PersistenceService.swift` (new migration `v11_recover_orphaned_quickpanel_cells`)
- Test: extend `Tests/TickerTests/StreamDocumentTests.swift`

- [ ] Migration: for each stream that has a `stream_documents` row, find `cells` rows with `created_at > stream_documents.created_at` (these are exactly the post-seed orphans the bug produced). Convert each cell's HTML to markdown-ish text (reuse `htmlToPlainText`, but first rewrite `<img src="X">` → `![capture](X)` so images survive), and append them under a trailing `## Recovered captures` heading with timestamps. Idempotent by construction (migrations run once); backup-before-migrate already exists (`:220-233`).
- [ ] Test: seed a temp DB with a document row + two later cells (one containing an `<img>`), run migrations, assert markdown contains both texts and the image token under the heading.
- [ ] Verify on a copy of the real DB: `cp ~/Library/Application\ Support/Ticker-Next/ticker.db /tmp/ && sqlite3` inspect before/after.
- [ ] Changelog entry: "Recovered quick-capture notes that previously didn't appear in streams."
- [ ] Commit: `fix(persistence): recover quick-panel captures orphaned in cells table`

---

## Phase 2 — Delete the cell era

Order matters: web first (proves nothing references it), then bridge messages, then Swift.

### Task 2.1: Delete the dead web cell cluster

**Files (delete):**
- `Web/src/store/blockStore.ts`, `Web/src/hooks/useBlockFocus.ts`
- `Web/src/components/`: `Cell.tsx`, `CellEditor.tsx`, `CellOverlay.tsx`, `PromptEditor.tsx`, `BlockWrapper.tsx`, `ReferencePreview.tsx`, `ReferenceSuggestion.tsx`
- `Web/src/extensions/`: `CellBlock.ts`, `CellBlockView.tsx`, `CellKeymap.ts`, `CellClipboard.ts`, `cellEmpty.ts`
- `Web/src/utils/`: `references.ts`, `referenceSuggestionCells.ts`, `html.ts`, `cellDrag.ts`, `cellTitle.ts`
- **Modify:** `Web/src/hooks/useBridgeMessages.ts` — reduce to: source sync, image drop, and settings; delete `EditorAPI.insertCells`/`replaceCellHtml`, the `quickPanelCellsAdded`, `aiChunk/aiComplete/aiError`, `modifier*`, `blockRefresh*` handlers, and all `blockStore`/`markdownToHtml` imports. Delete `Web/src/utils/markdown.ts` if `markdownToHtml` was its last consumer.
- **Modify:** `Web/src/App.tsx` (drop `clearStream` import), `Web/src/components/SidePanel.tsx` (remove the cells/outline branch; keep sources tab), `Web/src/components/StreamEditor.tsx` (drop `cells={[]}` prop and dead `editorAPI` members), `Web/src/types/models.ts` (remove `Cell`, `Modifier`, `ProcessingConfig`, reference types if unreferenced).
- **Modify:** `Web/package.json` — remove all `@tiptap/*`, `tippy.js`, `marked`, `dompurify`, `@types/marked`, `@types/dompurify`.

- [ ] Delete, then `cd Web && npm install && npm run typecheck && npm run build` → clean. Typecheck is the safety net; anything still importing the cluster surfaces here.
- [ ] Verify smoke: stream list, open stream, edit, image insert, search modal, settings.
- [ ] Commit: `chore(web): delete dead TipTap cell subsystem and dependencies`

### Task 2.2: Retire legacy bridge messages

**Files:**
- Modify: `Web/src/types/bridge.ts` (remove `cellSaved`, `cellDeleted`, `blocksReordered`, `quickPanelCellsAdded`, `aiChunk/aiComplete/aiError/aiStarted`, `modifier*`, `blockRefresh*`, `modelSelected` from the allow-list)
- Modify: `docs/contracts/bridge.v1.json` → mark retired messages (move the still-live non-cell messages into `bridge.v2.json`; goal: v2 is the complete contract, v1 kept only as historical reference and dropped from the checker merge in `tools/contracts/check_bridge_contract.mjs`)
- Modify: `Sources/Ticker/App/WebViewManager.swift` — delete `case "saveCell"` (`:1013-1090`), `"deleteCell"`, `"reorderBlocks"`, `"think"` (`:1260-1433`), `"applyModifier"` (`:1556-1635`), and any other cell-only cases; delete cell/modifier/version encoding in `encodeStream` (`:2095-2131`) and `decodeCell` (`:2338-2457`).

- [ ] Run `node tools/contracts/check_bridge_contract.mjs` → PASS with v2 as sole live contract.
- [ ] Verify: build + full editor smoke + document AI (`Send`, `Send & Prompt`, undo-in-one-step) + quick panel ↵ / ⌘↵ / ⌥↵.
- [ ] Commit: `chore(bridge): retire cell-era messages; v2 is the live contract`

### Task 2.3: Delete legacy Swift persistence/model code

**Files:**
- Modify: `Sources/Ticker/Services/PersistenceService.swift` — delete `saveCell`, `insertQuickPanelCells`, `getInsertionOrderForQuickPanel`, `isQuickPanelEmptyCellContent`, `getNextCellOrder`, `deleteCell`, `updateCellOrders`, `getCellContent`, `textSearchCells`/`CellSearchResult` (`:558-800`, `:1071-1148`), `initialMarkdownFromLegacyCells` seed usage in `loadOrCreateStreamDocument` (v11 already recovered the data; keep the function only if referenced by the migration), and cell decoding in `loadStream`.
- Modify/Delete: `Sources/Ticker/Models/Cell.swift` — delete if the quick panel no longer references it; otherwise strip to what migrations need.
- Modify: `Sources/Ticker/Services/SearchService.swift` — retarget text search from `cells.content` to `stream_documents.markdown`.
- Modify: `Sources/Ticker/Services/ProcessingService.swift` — cascade/refresh logic is cell-based; delete if its bridge entry points went away in 2.2 (verify with grep first).
- Test: update `Tests/TickerTests/DeviceKeyServiceTests.swift` — delete `PersistenceServiceQuickPanelTests` (they assert the removed model; Task 1.1's tests are the replacement).

- [ ] Grep-verify zero references before each deletion; `swift build && swift test` after each file.
- [ ] Do NOT drop the `cells` table itself in this pass (harmless, and it is the recovery source if v11 ever needs a re-run on a user DB). Note this with a `ponytail:` comment on the migration.
- [ ] Verify: search modal still finds stream content.
- [ ] Commit: `chore(persistence): delete cell-era write/read paths`

### Task 2.4: Delete dead AI providers; gate the inert RAG stack

**Files (delete):** `Sources/Ticker/Services/AIService.swift`, `AnthropicService.swift`, `PerplexityService.swift`
- Modify: `Sources/Ticker/Services/Providers/LLMProvider.swift` — delete the `LLMProvider` protocol; keep `LLMRequest`/`LLMMessage`/`LLMIntent`/`ProxyLLMError`/`ProxyQuotaDetails` (live value types).
- Modify: `Sources/Ticker/Services/AIOrchestrator.swift` — accept an injected `ProxyLLMService` instead of constructing its own (`:17`); `WebViewManager` passes its instance (fixes the double instantiation).
- Modify: `Sources/Ticker/Services/SourceService.swift` — skip chunking/embedding scheduling when embeddings are disabled (`SettingsService.proxyOnlyMode`), so source-add stops burning CPU for an index that is never queried. Keep `ChunkingService`/`EmbeddingService`/`RetrievalService`/`RAGMigrationService` files (they are the seed of a future retrieval feature) but ensure no runtime path invokes them under `proxyOnlyMode` — including the `migrateExistingSourcesToRAG` call at `WebViewManager.swift:731`.

- [ ] `swift build && swift test`; verify AI Send / Send & Prompt / quick panel AI still work (all go through `ProxyLLMService`).
- [ ] Commit: `chore(services): delete dead LLM providers, single ProxyLLMService, gate inert RAG`

---

## Phase 3 — Editor rendering & selection UX

### Task 3.1: Fix the image widget (perf, flicker, atomicity)

**Files:**
- Modify: `Web/src/extensions/MarkdownImageWidget.ts`

- [ ] `eq()` compares `raw` only (not `from`/`to`) so position shifts don't recreate DOM / reload `img.src` (`:94-96`).
- [ ] In `update()` (`:190-192`): on `viewportChanged`-only updates, map the existing set (`this.decorations = this.decorations.map(update.changes)`); rebuild only on `docChanged`, and only over changed ranges (iterate `update.changes.iterChangedRanges`, re-scan affected lines) instead of `view.state.doc.toString()` on every keystroke.
- [ ] Register `EditorView.atomicRanges.of(plugin => plugin.decorations)` so cursor/selection skip over the hidden `![...](...)` source instead of entering it.
- [ ] Verify: place an image mid-document; type rapidly above it → no flicker, no network/asset reload (watch the asset scheme handler logs); arrow-key across the image → cursor jumps over it in one step; resize handle still works.
- [ ] Commit: `fix(editor): stop image widget churn; atomic cursor traversal`

### Task 3.2: Live markdown concealment (the "elegant rendering" gap)

**Files:**
- Create: `Web/src/extensions/MarkdownConceal.ts`
- Modify: `Web/src/components/StreamEditor.tsx` (add extension at `:1030-1042`)

**Interfaces:**
- Produces `markdownConcealExtension: Extension` — a `ViewPlugin` that walks `syntaxTree(state)` over visible ranges and applies `Decoration.replace()` to formatting marks (`HeaderMark`, `EmphasisMark`, `StrongEmphasisMark`, `CodeMark`, `QuoteMark`, `LinkMark` + URL portion) **except on lines intersecting the current selection**, where raw markdown stays editable (Obsidian-style live preview). Links render the label text styled as a link; the URL is concealed until the cursor enters the line.

- [ ] Implement using `syntaxTree` node names from `@codemirror/lang-markdown` (no regex). Recompute on `docChanged || viewportChanged || selectionSet`; the decoration builder must only walk `view.visibleRanges`.
- [ ] Style pass in `Web/src/styles/index.css`: heading sizes move from `markdownHighlightStyle` into this system unchanged; blockquote gets a left border; concealed-line transition must not shift horizontal layout of non-mark text (marks are removed, not hidden with width).
- [ ] Verify: typing `## Title` then moving the cursor to the next line hides `## ` and shows a styled heading; clicking back into the line reveals the raw source exactly; bold/italic/inline-code/links/quotes behave the same; undo/redo and autosave unaffected; performance fine on a ~2,000-line document (paste one to check).
- [ ] Commit: `feat(editor): live markdown concealment for iA-style rendering`

### Task 3.3: Rebuild the selection popover on CodeMirror state

**Files:**
- Modify: `Web/src/components/StreamEditor.tsx` (`:501-614`, `:769-807`, `:980-1012`)

**Interfaces:**
- Replace the `document.selectionchange` + `window.getSelection()` mechanism with an `EditorView.updateListener` (or small ViewPlugin): on `update.selectionSet`, if `!state.selection.main.empty`, debounce 180ms, then position the menu from `view.coordsAtPos(selection.main.head)` (fall back to `.anchor` when head coords are null). Keep the existing gating (`showPrompt || isAiThinking` hides it) and the existing Send / Send & Prompt actions unchanged.

- [ ] Implement; delete `getFloatingMenuPlacement` and the `selectionchange`/scroll/resize DOM listeners (CM coords are viewport-relative — reposition inside the same updateListener on `geometryChanged`).
- [ ] Verify in the real app (WKWebView, not just a browser): select text with mouse → menu appears near selection; select with shift+arrows → appears; collapse selection → disappears; scroll while selected → menu tracks; Send replaces selection and one ⌘Z restores pre-AI state.
- [ ] Commit: `fix(editor): selection action menu driven by CodeMirror selection state`

### Task 3.4: Quick Panel ergonomics polish

**Files:**
- Modify: `Sources/Ticker/App/QuickPanel/QuickPanelWindow.swift`, `QuickPanelView.swift`, `QuickPanelManager.swift`

- [ ] Unify dismissal semantics: route `QuickPanelWindow.cancelOperation`/`keyDown` Esc (`:78-87`) through the same graduated `handleEscape` the text view uses, so Esc behavior is identical regardless of focus.
- [ ] Fix blur-dismiss vs the stream picker: in `windowDidResignKey` (`:39-42`), do not hide while the picker menu is open (track menu-open state around the SwiftUI `Menu`, or switch the picker to a popover owned by the panel window). Reproduce first: open picker, observe whether panel dismisses mid-selection.
- [ ] Add visible save feedback: after a successful append, flash a brief "Saved to <stream>" confirmation in the panel before hiding (the panel currently hides instantly, which is why saves feel uncertain even when they work).
- [ ] Update `docs/START_HERE.md:96-115` Quick Panel + drag-drop sections to match actual behavior (document-model saves, real error strings).
- [ ] Verify: full quick-panel matrix — ↵ / ⌘↵ / ⌥↵ / Esc×2 / click-outside / picker selection — behaves per the updated doc.
- [ ] Commit: `fix(quickpanel): consistent dismissal, picker stability, save feedback`

### Task 3.5: Visual coherence pass (design tokens + one surface language)

**Files:**
- Modify: `Web/src/styles/index.css`, `Web/src/components/` (styling only), `Sources/Ticker/App/QuickPanel/QuickPanelView.swift` (visual constants only)

Goal: the app should read as ONE instrument — calm, typographic, low-chrome (iA Writer register) — instead of several features styled at different times.

- [ ] Inventory pass first (report before changing): every hardcoded color, font-size, radius, shadow, and spacing value in `index.css` and inline styles; every SwiftUI color/font in the Quick Panel. List duplicates and near-duplicates (e.g. three slightly different grays, two radii).
- [ ] Tokenize: CSS custom properties on `:root` — a type scale (editor body, heading steps used by the conceal layer in 3.2, UI caption), a 4/8px spacing scale, one radius, one shadow (overlays), and a semantic color set (`--bg`, `--surface`, `--text`, `--text-muted`, `--accent`, `--border`) with light/dark values. Replace all hardcoded values with tokens; delete the orphaned rules that no longer match any live component (post-Phase-2 there will be dead cell CSS — remove it here if 2.1 missed any).
- [ ] One overlay language: SearchModal, Settings, the Send & Prompt overlay, ToastStack, and the selection action menu share the same surface token set (background, border, radius, shadow, backdrop). No component-private variants.
- [ ] Editor canvas: enforce a comfortable measure (max-width ≈ 68ch, centered), consistent vertical rhythm between paragraphs/headings/blockquotes/images, and make the PDF pane header (Task 0.1) visually match the stream header chrome.
- [ ] Quick Panel: align its fonts/colors/radius with the same palette so capture feels like part of the app, not a floating stranger.
- [ ] Verify: side-by-side screenshots (light + dark) of stream list, editor with all markdown elements + an image, search modal, settings, quick panel, PDF pane — reviewed by the governor before commit.
- [ ] Commit: `style: design tokens and coherent surface language`

---

## Phase 4 — Swift shell decomposition & bridge hardening

### Task 4.1: Extract the composition root

**Files:**
- Create: `Sources/Ticker/App/ServiceContainer.swift`
- Modify: `Sources/Ticker/App/WebViewManager.swift` (`init`, `:65-163`), `Sources/Ticker/App/AppDelegate.swift`

- [ ] Move the object-graph construction (`:65-132`) into `ServiceContainer` (plain struct, no framework); `AppDelegate` builds it once and injects into `WebViewManager` and `QuickPanelManager` (which already share `PersistenceService`/`BridgeService` — keep that).
- [ ] Verify: build + launch + quick panel + AI smoke.
- [ ] Commit: `refactor: extract ServiceContainer composition root`

### Task 4.2: Split `processMessage` into feature handlers

**Files:**
- Create: `Sources/Ticker/App/Bridge/BridgeRouter.swift`, `StreamMessageHandler.swift`, `SourceMessageHandler.swift`, `AIMessageHandler.swift`, `ProxyAuthHandler.swift`, `SettingsMessageHandler.swift`, `SearchMessageHandler.swift`
- Modify: `Sources/Ticker/App/WebViewManager.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol BridgeMessageHandler {
      var handledTypes: Set<String> { get }
      func handle(_ message: BridgeMessage, reply: @escaping (BridgeMessage?) -> Void) async
  }
  final class BridgeRouter { func register(_ handler: BridgeMessageHandler); func route(_ message: BridgeMessage) async }
  ```
  Unknown message types log AND send an error message back to JS (no more silent default case).

- [ ] Mechanical move: each `case` body relocates verbatim into its handler; handlers get their dependencies from `ServiceContainer`. One handler per commit, keeping the app building/running between commits. Do NOT refactor logic while moving (behavior-preserving; logic cleanups are separate tasks).
- [ ] `encodeStream`/`encodeSource`/`formatStreamForExport`/`stripHTML`/`sanitizeFilename` move to `Sources/Ticker/App/Bridge/StreamCodec.swift` — they have no WKWebView dependency. Deduplicate the 3× stream-summary payload block (`WebViewManager.swift:364-381, 830-843, 963-979`) into one `StreamCodec.encodeSummaries` used by all senders.
- [ ] Verify after each move: build + the feature's smoke test; final `WebViewManager` should be < 400 lines (webview ownership, navigation delegate, drop coordination, router wiring).
- [ ] Commits: `refactor(bridge): extract <Feature>MessageHandler` (one per handler)

### Task 4.3: Bridge hardening

**Files:**
- Modify: `Sources/Ticker/App/BridgeService.swift`, `Sources/Ticker/Models/BridgePayloads.swift`, `docs/contracts/bridge.v2.json`, `tools/contracts/check_bridge_contract.mjs`, `Web/src/types/bridge.ts`

- [ ] Fix `AnyCodable` number ambiguity: decode JSON numbers as `Double` first when the value has a fractional representation need — concretely, keep `Int` decode but add a `doubleValue` accessor used everywhere a numeric payload is read (grep every `as? Double` on bridge payloads and switch to it).
- [ ] Standardize streaming correlation on `requestId` (rename the `cellId` correlation key in any surviving streaming messages; `thinkDocument` already uses `requestId` at `WebViewManager.swift:1436`).
- [ ] Add inbound (Web→Swift) message contract to `bridge.v2.json` and extend `check_bridge_contract.mjs` to statically scan `bridge.send(` / `sendAsync(` call sites in `Web/src` the same way it scans Swift senders.
- [ ] Surface silent failures: `BridgeService` decode errors and handler `guard` failures send a `bridgeError { type, reason }` message to JS, which shows a toast in dev builds (`ToastStack` exists).
- [ ] Verify: `node tools/contracts/check_bridge_contract.mjs` passes; intentionally send a malformed message from the JS console → toast appears in dev.
- [ ] Commit: `fix(bridge): inbound contract, unified correlation ids, surfaced errors`

### Task 4.4: Autosave revision guard (closes the LWW hole)

**Files:**
- Modify: `Sources/Ticker/Services/PersistenceService.swift`, the stream handler from 4.2, `Web/src/components/StreamEditor.tsx`

- [ ] Add `revision INTEGER NOT NULL DEFAULT 0` to `stream_documents` (migration v12). `appendToStreamDocument` and `saveStreamDocument` increment it; `saveStreamDocument` takes the editor's `baseRevision` and, on mismatch, appends any DB content the editor's blob is missing instead of overwriting (in practice: reject the save, send `streamDocumentConflict { markdown, revision }`, editor reloads doc — simplest correct behavior; conflicts are rare since 1.3 applies appends live).
- [ ] `streamLoaded`/`streamDocumentAppended` carry `revision`; editor tracks it alongside `lastSavedContentRef`.
- [ ] Test in `StreamDocumentTests.swift`: save with stale revision does not clobber an interleaved append.
- [ ] Commit: `fix(persistence): revision-checked saves prevent external-write clobbering`

---

## Phase 5 — Production hardening

### Task 5.1: Test net for the document model

- [ ] `Tests/TickerTests/StreamDocumentTests.swift` grows: load/create/append/save/revision matrix; migration backup created only when migrations pending; v11 recovery idempotence.
- [ ] Add `Web` vitest setup with the first tests: conceal extension (marks hidden off-selection, revealed on-selection), append-transaction handler, popover show/hide logic (pure function extracted for testability). Keep it to the logic that broke before — no snapshot theater.
- [ ] Commit per test file.

### Task 5.2: CI

- [ ] Add `.github/workflows/ci.yml` per `docs/GITHUB_BACKLOG_ALPHA.md` A3: Swift build + `swift test` + `cd Web && npm run typecheck && npm test` + `node tools/contracts/check_bridge_contract.mjs`. Branch protection per A1.
- [ ] Commit: `chore(ci): build, tests, bridge contract check`

### Task 5.3: Docs truth pass

- [ ] `docs/DATA_MIGRATIONS.md`: document the real path `~/Library/Application Support/Ticker-Next/` (decision: keep the fork-isolated directory; it prevents clobbering old-Ticker data — update the doc, not the code).
- [ ] `docs/START_HERE.md`: Quick Panel section rewritten for the document model (done in 3.4 — verify), local-data section drops "cells" language.
- [ ] `docs/contracts/README.md`: v2 is canonical; v1 historical.
- [ ] `CHANGELOG.md`: entries for every user-facing fix above.
- [ ] Commit: `docs: align docs with document-model reality`

### Task 5.4: Release gate

- [ ] Full AGENTS.md verification baseline on a Release build (`./tickerctl.sh run-prod`): open/edit/copy-paste/AI+undo/save-reload/images/PDF round-trip/quick panel matrix/search/settings/export.
- [ ] Run `docs/ALPHA_READINESS_CHECKLIST.md`.
- [ ] Tag per `docs/RELEASES.md`.

---

## North Star: Document Reading

The product direction after stabilization is **proper document-reading support**: read a PDF alongside a stream, take structured notes anchored to exact locations, link stream text to PDF sections (not just highlights), generate summaries of sections, and get suggested further readings. Later: richer annotation types (small code blocks, figures, tables). Every stabilization phase above feeds this: Phase 0/4 give the PDF pane a clean controller and bridge seam; Phase 1's `appendToStreamDocument` is how reading artifacts (notes, summaries, citations) flow into streams; Phase 3's conceal layer is where anchor links render as calm inline affordances. Features 3, 4, and 7 below are the concrete first steps.

## Feature Surfaces (post-stabilization, not scheduled)

The stabilization work above *creates* the extension architecture; these ride on it. The plugin story is: **on the web side, a feature = a CodeMirror 6 extension (already a first-class plugin system — the image widget and conceal layer prove the pattern); on the Swift side, a feature = a `BridgeMessageHandler` registered with `BridgeRouter` (Task 4.2) plus contract entries in `bridge.v2.json` enforced by the checker.** A new capability touches zero existing files beyond registration — that is the modular/plug-in surface, without inventing a plugin framework nobody asked for.

Candidates, roughly ordered by leverage:

1. **Selection-action registry.** Generalize the popover (3.3) from two hardcoded buttons to a registered action list: Send, Send & Prompt, then Rewrite/Summarize/Define, "Link to PDF highlight", "Copy as quote". Each action = `{label, handler(selection, view)}`. This is the natural home for the "suggestive pop-ups" ambition.
2. **Stream cross-links + backlinks.** `[[stream-title]]` syntax as a CM extension (autocomplete on `[[`, concealed rendering, click-to-navigate) plus a backlinks drawer. The deleted references code was groping at this; the document model makes it a weekend feature instead of a schema project.
3. **Ask-your-sources (revive RAG properly).** The chunking/embedding/retrieval stack survives behind its flag (2.4). When the proxy grows an embeddings endpoint, turn it on and add a "ask across this stream's sources" mode to Send & Prompt, with answers citing chunk page ranges that deep-link into the PDF pane (the highlight-link plumbing from Phase 0 already navigates there).
4. **PDF anchors, bidirectional.** MVP contract §9 promises editor→highlight AND highlight→editor. The current branch does editor→PDF; add stable anchor IDs in markdown (`[▸ p.12](ticker-pdf://source/highlight)`) and a "show in stream" affordance on PDF highlights.
5. **Export/publish.** `StreamCodec.formatStreamForExport` already exists; expose Markdown/HTML export with assets bundled, and a "copy as rich text" for pasting into mail/docs.
6. **Capture API surface.** Once `appendToStreamDocument` + `streamDocumentAppended` is the single write primitive (Phase 1), *anything* can be a capture source: a share extension, a CLI (`tickerctl append`), a URL scheme (`ticker://append?stream=…`). The Quick Panel becomes just the first client of a general append API — this is the highest-leverage architectural payoff of the P0 fix.
7. **Reading sessions (the document-reading core).** With a PDF open in the pane: (a) **section anchors** — use the PDF outline (`PDFDocument.outlineRoot`) plus page/selection geometry so links can target sections, not just ad-hoc highlights; (b) **anchored notes** — select in the PDF → "Add note" appends a note block to the stream carrying the anchor, so notes are ordinary markdown that deep-links back; (c) **section summaries** — "Summarize section" runs the orchestrator over the section's extracted text (ChunkingService already computes page ranges) and appends a cited summary; (d) **further readings** — the proxy already fronts an LLM; a "suggest readings" action over the document's extracted text is a prompt, not an architecture. All four are just selection-actions (feature 1) + append-API clients (feature 6) + PDF anchors (feature 4) composed — which is why the stabilization order matters more than starting any of them early.
8. **Richer annotation blocks (later).** Small code blocks with syntax highlight already work in CodeMirror's markdown; "proper support" means conceal-layer styling for fenced blocks (3.2) and, later, dedicated widgets (like the image widget pattern) for callouts/figures. No new data model needed — it stays markdown.

---

## Roadmap 2: Reading with Receipts (scheduled — supersedes Feature Surfaces §3/§7 scheduling)

**The wedge:** ask a question about your sources and get an answer where every claim is a clickable citation that opens the PDF at the exact passage, highlighted and centered. Ticker owns both sides of the reading loop (reader with persistent positional anchors + markdown notebook where anchors are live links); no competitor owns both. The architecture goal underneath: **per-question cost scales with what's relevant, never with the size of the book** — ingest once, ask many.

### Design tenets (every task below must respect these)

1. **Reading is never blocked by processing.** A dropped PDF is readable instantly; extraction/indexing happen behind a quiet status. No spinners as theater — status text under the source row that resolves to *absence* when ready.
2. **Routing is automatic; provenance makes it visible; the user can override, never must.** No "RAG mode" toggle, no settings page. The answer itself shows where it came from: citations = from your sources; no citations + a muted "from model knowledge" note = the model answered alone. A compact scope chip in the prompt popover (`Sources: Auto / All / None`) is the escape hatch when auto-dispatch guesses wrong (e.g. "current stock prices" must not be answered from a history book — threshold gating handles this without ML; see 2.4). **Dispatch is a filter, not a router**: one pipeline (retrieve → score → threshold → include what clears the bar); the user-visible cases — plain send / send with captured context / source question / ambiguous / unrelated — are emergent behaviors of that single rule, never separate code paths. **User-captured context (quick-panel selection, screenshots) is always included verbatim** — it is the user's explicit choice, orthogonal to and never displaced by retrieval. **Grounded, not caged**: the prompt instructs the model to use retrieved passages *plus its own knowledge*, citing passages when used (owned by 1.3/2.1). Continuous-conversation-with-standing-source-context is a prompt-caching optimization for the small-source whole-text path (proxy-side, later) — it does not replace retrieval for books (first turn still ships the book; caches expire; long contexts degrade answers).
3. **Citations ARE markdown links.** AI citations are ordinary `[Book p.112](ticker-pdf://…)` links — they reuse the entire existing pipeline: conceal rendering, click→open+center+pulse, GC on deletion, export. No parallel citation system.
4. **The model never fabricates URLs.** The model emits opaque markers (`【1】`) referencing a numbered chunk manifest we assemble; post-processing swaps markers for links we generate ourselves. A citation can only point at something we actually retrieved.
5. **Local by default, remote only for generation.** Chunking + FTS index are free and local (Phase R1 needs no model at all). Embeddings local via MLX (Phase R3). Only generation and (lazily) summarization spend proxy tokens.
6. **Pay-per-use ingest.** Extraction/chunking/FTS at add time (free). The summary tree (which costs tokens) builds lazily on first whole-book question or reading-session use, with a one-time visible "Preparing summaries…" state — users never pay for books they don't interrogate.
7. **Honest failure states.** Encrypted or scanned PDFs (no text layer) get a plain-language status ("No readable text — this looks like a scanned document") + retry, not silent emptiness. A question asked while indexing is answered with what's ready plus a subtle "still indexing X" notice chip — never an error.

### How the user encounters it (walkthrough)

- **Add a 250-page book** → row appears in the sources modal immediately, PDF opens and reads instantly; under the row: "indexing · p. 118/250" (thin, muted), then nothing. Failure → honest state + Retry.
- **Ask about the book** (selection Send & Prompt, or ⌘L against the stream) → answer streams in with `【1】` markers that resolve to `[Forth Handbook p. 112]` links at completion; a muted trailing line: *Consulted: Forth Handbook (4 passages)*. Click a citation → pane opens, page scrolls centered, passage flashes.
- **Ask about stock prices in the same stream** → retrieval scores fall below threshold → no chunks sent, no citations shown, answer carries *from model knowledge*. If the router guessed wrong, the scope chip on the prompt popover forces `All` next time.
- **Multiple sources** → citations are disambiguated by short source name; the Consulted line lists per-source counts. Same click behavior per source.
- **"Summarize chapter 3" / "what's this book about"** → routed to the summary tree; first such question triggers the one-time "Preparing summaries… (~1 min)" state, cached forever after.

### Known bites (identified up front, owned by specific tasks)

- **Scanned PDFs / no text layer** → honest status now (1.2); VisionKit OCR is a later phase, explicitly out of scope.
- **Chunk anchors have page ranges, not rects** → citation click does `PDFDocument.findString` on the chunk's leading sentence *at click time* to get rects for flash; page-only fallback if not found (2.2). No rect storage for chunks.
- **Streaming vs. post-processing** → markers stream visibly, swap to links on completion inside the existing one-undo-step apply (2.1). Brief marker flicker accepted.
- **Deleting a source** → cascade-delete its chunks/index rows (1.1); its citations become dead links → ships with the friendlier dead-link toast (2.3, folds in the existing follow-up).
- **Existing sources predate indexing** → backfill lazily on stream open, never a startup migration stall (1.1).
- **Tiny sources don't need retrieval** → if a stream's total extracted text < ~8k tokens, send it whole (current behavior); retrieval engages only past that. Nobody's meal-prep plan gets worse (1.3).
- **Embedding model download (~100 MB)** is a UX moment: explicit consent + progress in Settings, app fully functional without it (R3 only).
- **Prompt caching needs proxy changes** → separate Ticker-Proxy work, out of scope for all phases here.

### Phase R1 — Retrieval foundation (FTS5, no embeddings, no new models)

- **Task 1.1 — Ingest pipeline + schema.** v16 migration: `source_chunks(id, source_id → cascade, seq, text, page_start, page_end, section_path)`, FTS5 virtual table over chunk text, `sources.index_status` (`pending/indexing/ready/failed_no_text/failed`). New `IngestService` (async, one source at a time): extract per page → outline-aware chunking via reworked `ChunkingService` (use `PDFDocument.outlineRoot` section tree when present; else ~800-token overlapping windows) → FTS insert. Bridge event `sourceIndexStatusChanged {sourceId, status, progress?}` (contract + allow-list). Lazy backfill: on stream open, enqueue any `pending` legacy sources. Files: `Services/IngestService.swift` (new), `Services/ChunkingService.swift`, `Services/PersistenceService.swift`, `Bridge/SourceMessageHandler.swift`, contract. Tests: migration, chunker page-range correctness, cascade delete.
- **Task 1.2 — Status UI.** Sources modal rows show the quiet status line + failure states + Retry; "N pages · indexed" when ready. Answer-area notice chip for ask-while-indexing. Files: `SourcesModal.tsx`, `StreamEditor.tsx`, `index.css` (tokens only).
- **Task 1.3 — Retrieval replaces concat.** Rework `RetrievalService`: BM25 query over the stream's sources → top-k (k≈8) with a relevance threshold. `AIMessageHandler`/`AIOrchestrator`: if total extracted text small → legacy whole-text path; else retrieved chunks only, formatted as a numbered manifest with source/page metadata. Below-threshold → no source context (sets up "from model knowledge"). Tests: threshold gating, small-source passthrough, multi-source interleave.
- **Task 1.4 — Scope chip.** Prompt popover gains `Sources: Auto / All / None` (default Auto, session-sticky per stream). `All` forces whole-text-or-top-k-unthresholded; `None` skips retrieval. Bridge: extend thinkDocument payload with `sourceScope`.

### Phase R2 — Citations (the wedge made visible)

- **Task 2.1 — Marker protocol.** Prompt instructs the model to cite manifest entries as `【n】`. Post-process on completion (inside the existing one-undo apply): swap markers for `[<short-source-name> p.<page>](ticker-pdf://<sourceId>?page=<n>&chunk=<id>)` links generated from the manifest — never from model text. Unknown markers dropped silently. Web tests for the swap.
- **Task 2.2 — Citation navigation.** Extend `openPdfDestination` handling: `chunk=<id>` → load chunk, `findString` its leading sentence → temporary flash annotation on found rects (reuse pulse), centered (existing behavior); fallback to page. Swift tests for find-fallback.
- **Task 2.3 — Provenance strip + honest states.** Muted trailing line after cited answers (*Consulted: X (n), Y (m)*); *from model knowledge* note when no chunks were sent; friendlier dead-link toast for any `ticker-pdf://` failure (source deleted / other stream / corrupted), replacing the silent no-op.

### Phase R3 — Local embeddings + hybrid retrieval

- **Task 3.1 — MLX embedding backend.** Small local model (bge-small class) behind the existing `EmbeddingService` interface (replacing the 1536-dim remote assumption); Settings row with explicit download consent + progress; app fully functional without it (BM25-only).
- **Task 3.2 — Vector store + fusion.** Chunk vectors as BLOBs in SQLite; Accelerate brute-force cosine (personal-corpus scale; no vector DB); reciprocal-rank fusion with BM25.
- **Task 3.3 — Eval gate.** ~30-question golden set over 2–3 real PDFs in `Tests/`; hybrid must beat BM25-only on retrieval hit-rate before default-on.

### Phase R4 — Summary tree + reading sessions

- **Task 4.1 — Lazy summary tree.** Per-section summaries (outline tree, cheap model via proxy) rolled up to chapter/book, cached in `source_summaries`; built on first whole-book question with the one-time visible state. Router: whole-book/section questions → tree (+ top-k chunks for section questions).
- **Task 4.2 — Reading-session basics.** Persist per-source last scroll position (resume on open); "Summarize this section" action in the PDF pane header (outline-aware) appending a cited summary block via the append API.

### Phase R5 — sketched, not scheduled

Cross-stream corpus ("what have I read about X"), connections/suggested passages from your own library while writing, `ticker-web://` universal capture, share/export with working citations. Also: **source search UI** — stream search already exists (`SearchService.hybridSearch`); Task 1.1's FTS index makes "find in this source / all sources" a thin UI over existing infrastructure — near-free follow-on once R1 lands. Plan when R1–R4 are live.

### Explicitly not doing (v1)

GraphRAG, ColBERT/late-interaction, external vector stores, agentic multi-hop retrieval, web search dispatch, ML-based query routing (threshold gating first; revisit the small dispatching model only if thresholds measurably misroute).

---

## Roadmap 3: Field Hardening (post-v2026.7.2, from first-round user testing)

Written 2026-07-05 after the first two external testers + the field-fix phase (PR #36). Theme: the data core held; **every failure was at a seam** — OS permissions, other apps' AX servers, AI dispatch, ops. Ordering principle: user-trust bugs first, abuse surfaces before wider distribution, scale robustness after.

### Design tenets (carried forward + new)

- Wrong context is worse than no context (established in R2 for citations; now applies to *capture*: never silently attach text the user didn't select).
- An attached source is a declaration of intent — dispatch must be strongly biased toward it. The cost asymmetry is extreme: false-include costs tokens; false-exclude costs trust and is invisible to the user.
- Every capture/permission failure gets an honest, actionable message (no generic states).
- Field telemetry over reproduction: the feedback bundle (FF4) is the debugging channel for machines we'll never see.

### Phase H1 — Trust & correctness (P0)

- **Task H1.1 — Source-biased dispatch.** Reported live: lease questions in plain English scored below the BM25 cutoff against lease legalese → silent fallback to model knowledge ("From model knowledge" strip) with the lease attached. Fix in `assembleSourceContext` (the one decision point): (a) when the stream has ≥1 non-private source and scope=Auto, drop the per-token cutoff substantially (measure; start ~half); (b) single-source streams: if retrieval passes nothing, fall back to passthrough when the source fits the token budget, else include top-k regardless of threshold with the manifest marking low-confidence; (c) provenance strip keeps over-inclusion auditable. **Golden set** (seeds the R3 eval gate): lease-style paraphrase questions (must retrieve), the pasta-vs-Forth case (must still gate), numeric-conversion case (must retrieve). Acceptance: all three pass live.
- **Task H1.2 — Clipboard-rung wrong-capture guard.** VS Code-class apps copy the cursor line on ⌘C-with-no-selection → rung 3 can attach a line the user never selected. Fix: capture attribution — context captured via the clipboard rung is labeled in the panel (e.g. "captured via clipboard") and remains dismissible; additionally suppress rung 3 when the frontmost app is a known copy-line editor (small denylist: VS Code, Cursor, Zed) unless rung-1/2 errors indicated a real selection. Tenet: wrong-worse-than-none.
- **Task H1.3 — Crash root-cause + sentinel audit.** Blocked on tester's `.ips` (requested). Independent: audit `applicationWillTerminate` coverage — Sparkle's update relaunch may skip it → `last_session_crashed` false positives after every update; fix by also clearing the marker on Sparkle's pre-relaunch hook (or tolerating: marker + recent-update flag = suppress).
- ~~**Task H1.4 — Single-instance DB lock.**~~ **DROPPED (2026-07-05, user):** macOS LaunchServices already prevents a user from launching a second copy of one app bundle, so a real user can never get two instances against one DB. The only two-instance path is the *developer* one (debug `io.ticker.next.debug` + release `io.ticker.next` sharing `Application Support/Ticker-Next`). That's dev hygiene, not a shipped runtime lock. **Replacement (dev-only, optional):** give Debug builds a separate app-support dir (`Ticker-Next-Debug`) so dev testing can't touch the real user DB — also removes the copy-DB-aside dance before every governor live-test.

### Phase H2 — Abuse & ops (P1, before sharing install links wider; Ticker-Proxy repo)

- **Task H2.1 — Proxy quota hardening.** Every install provisions a device key against the owner's spend, and the repo/releases are public. Per-device daily/monthly token caps (server-enforced, 402-style error the app surfaces honestly), device-key revocation list, admin console visibility of per-device spend, alerting threshold.
- **Task H2.2 — Feedback endpoint limits.** FF4 attaches crash logs + log rings; cap request body size server-side, rate-limit per device, reject oversized attachments with a clear error (client already caps at 10MB — enforce lower server-side, ~1MB metadata + attachment cap).
- **Task H2.3 — First-run capture self-test.** Onboarding gains a "try it now" step: select sample text in the onboarding window itself → ⌘L → confirm capture end-to-end (uses the internal provider — no permission needed), then an external-capture check with live status using the FF-phase outcomes (incl. stale-grant canary). Kills the "granted but nothing happens, silently" first-run experience.

### Phase H3 — Capture UX (P2)

- **Task H3.1 — Recent-clipboard-text context (approved 2026-07-05: 15s window; do NOT rely on kitty `copy_on_select`).** Flow: user copies text anywhere (⌘C), presses ⌘L within **15 seconds** → the copied text is attached as context, visibly attributed and dismissible. Universal, AX-independent terminal/remote-desktop answer. Implementation spec:
  - **Model on the existing clipboard-image affordance.** `QuickPanelContext` gains `clipboardText: String?` alongside `clipboardImage`; attach in `SelectionReaderService.buildContext` only when `hasSelection == false` (any ladder rung winning always takes precedence).
  - **Recency**: reuse/extend `ClipboardService.wasRecentlyModified` with a 15s threshold (NSPasteboard has no timestamps — the service already tracks observed `(changeCount, Date)` pairs for images; text uses the same tracking, no new poller).
  - **No self-pollution**: the synthetic-⌘C rung must not create phantom "recent copies." Current code is already safe — on rung-3 failure the pasteboard is untouched (restore only runs after a successful bump), and on success the outcome isn't empty so this path isn't consulted — but the Codex task must assert this with a test, not assume it.
  - **Type precedence**: if the pasteboard item has a non-empty `.string` after trimming, prefer text; else fall back to the existing image behavior (screenshots carry no string type, so image capture is unaffected).
  - **Privacy guards**: skip items marked `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` (password managers); cap attached text (~10k chars, truncate with visible ellipsis).
  - **UI**: attribution chip in the panel ("Copied text · ⟨preview⟩") with dismiss; dismissal recorded via a `suppressedClipboardTextChangeCount` mirroring the image pattern (same copy never re-offers). The `emptyExternal` status line gains the teaching hint: "No text selected in ⟨App⟩ — copy it (⌘C) and press ⌘L to attach."
  - **Tests**: pure decision logic (recent ∧ text ∧ not-suppressed ∧ not-concealed → attach; selection present → never), suppression round-trip, truncation, and the no-self-pollution assertion. No bridge/contract changes (native only).
- **Task H3.2 — Panel latency.** Worst-case honest-empty capture costs ~300–600ms of ladder polling before the panel shows. Show the panel immediately with a "capturing…" shimmer state; hydrate context when the ladder resolves. Capture-before-focus-steal must be preserved (read the AX snapshot synchronously first; only the slow rungs go async).
- **Task H3.3 — AX hint hygiene (low).** `AXEnhancedUserInterface` is set on Chromium/Electron apps and never unset (persists for the target app's lifetime; can alter its behavior/perf). Unset on Ticker quit for hinted pids still running; document the tradeoff.

### Phase H4 — Ingest & scale robustness (P2, power-user)

- **Task H4.1 — Ingest failure taxonomy.** Scanned/no-text-layer PDFs, encrypted PDFs, extraction exceptions, zero-chunk outcomes → distinct, honest status lines in SourcesModal ("No text layer — this PDF can't be indexed (scanned?)"), not a generic failure; Retry only where retrying can help. Telemetry: outcome counts in the support bundle.
- **Task H4.2 — Large-document perf pass.** Measure then fix: autosave payload on multi-MB markdown docs (full-doc save every 350ms debounce — consider content-hash skip), stream list with 200+ streams, FTS index size/vacuum on big libraries, editor open time on huge docs. Budget: no user-visible degradation at 10× current test corpus.

### Phase H5 — Retrieval quality (R3 of Roadmap 2, unchanged)

Local MLX embeddings + hybrid retrieval behind the same `assembleSourceContext` seam, gated by the eval harness seeded in H1.1. The real fix for the lexical-mismatch class that H1.1 mitigates heuristically.

### kitty / terminal capture — position (not a task)

Probes (2026-07-05) proved: kitty 0.26.2 (Sept 2022 binary, unchanged) answers `AXSelectedText` with an empty string on macOS 26.5 while a live selection exists; the system-wide AX focus query fails outright (kAXErrorCannotComplete); synthetic ⌘C never triggers its copy binding (plain keys deliver; modifier shortcuts don't). The same app+mechanism worked on earlier macOS — this is OS-evolution breakage on a 2022-era AX implementation, not a Ticker regression (legacy repo #121 documents the same class on Sequoia). Path: (1) user upgrades kitty — verify current kitty's AX on macOS 26 before promising; (2) H3.1 clipboard-text rung + kitty `copy_on_select yes` = capture restored regardless of AX; (3) optional later: kitty remote-control integration (`kitten @ get-text --extent selection`, requires `allow_remote_control`) as a documented power-user path. Do not sink more time into synthetic-event delivery for GLFW apps.

---

## Codex Execution Protocol (governor rules)

- One Codex session per phase, resumed each round with the explicit session id (never `resume --last`); cold-start a fresh session if the rollout shows >1 compaction. `-s workspace-write` before the `resume` subcommand.
- Round prompt template: paste the single task (files, interfaces, steps, verification) + the Global Constraints block. Codex must not read ahead or batch tasks.
- Claude reviews the diff after every task before the next round: constraint check (no cell-model reintroduction, no split-pane, contract checker passes), then verification commands re-run independently.
- Branch per phase: `codex/phase-1-capture-pipeline`, etc. PR per phase to `main`; changelog entry required.
- Escalate to the user only for: destructive data operations on real user DBs, UX decisions the MVP plan leaves open, scope changes.
