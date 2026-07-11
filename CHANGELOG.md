# Changelog

All notable user-facing changes to Ticker are documented here.

## Unreleased

### Added
- A global AI Activity Capsule now follows Quick Panel work across streams, shows each phase and outcome, and lets you stop an active request.
- Underline joins bold and italic: ⌘U and a U button in the selection menu (stored as `<u>` in the markdown substrate, rendered with the tags concealed).
- AI answers now use rudimentary Markdown structure — bolded key terms, short paragraphs, lists and headings where they genuinely organize the material — instead of uniformly flat prose.
- Source answers now use on-device semantic retrieval alongside lexical matching, improving paraphrase recall while preserving the existing fallback behavior.
- The Rewrite menu gained "With instructions…": describe how the selection should be rewritten and the AI replaces it accordingly. Re-develop with an edited prompt now actually obeys the prompt (it previously deferred to the fixed "develop" instruction and near-restated the passage).
- In-editor AI now shows the same pulsing-dots indicator at the exact insertion point while waiting for the first chunk, matching quick-panel dispatches.
- ⌘F opens search from the stream list (⌘K still works everywhere; in the editor ⌘F remains in-document find).
- ⌘B and ⌘I now toggle bold and italic on the stream editor selection.
- Quick Panel AI answers now show presence in the open editor: the AI-writing pill plus a typing indicator pinned to the exact spot where the answer will land.
- Settings now offers a model choice — Balanced (GPT-5 mini), Fast (GPT-4o mini), or Claude — with web search available on the OpenAI options.
- Search-vs-knowledge routing now uses Apple's on-device foundation model when available (macOS 26 + Apple Intelligence), with the keyword gate as fallback.
- Provenance x-ray now tints each AI exchange with its own color variant so neighboring exchanges read as distinct, and the exchange overlay gained a proper title bar with a close button.
- Selection menu now offers heading (H1/H2/H3), quote, and bullet-list toggles, and a new stream-editor footer has a "Show formatting" switch that reveals the raw markdown document-wide.
- `ticker://` URLs can now append text to an existing stream or open a stream by id.
- Quick Panel ephemeral answers now use the picked stream's sources and keep citation links when saved.
- PDF sources now reopen to the last-read page, expose document outlines when available, and describe pane failures in text.
- Markdown links now open on click and can be edited from a compact popover without exposing raw URL markup.
- Streams now restore editor scroll position and hide the first frame until markdown concealment is ready.
- Stream list cards now show content previews, word counts, and global search from the list.
- Untitled streams can now keep their titles updated from document text until renamed manually.
- Quick Panel can now attach recently copied clipboard text as context when no live selection is available.
- Quick panel now detects a stale Accessibility grant (permission shown as on but revoked by macOS) and says exactly how to fix it.
- Sources can now be marked Private so their contents stay out of AI context while remaining locally searchable and readable.
- Stream editor headers now keep long titles to one calm ellipsized line without crowding actions or document content.
- Document AI citation links can now carry exact evidence quotes so PDF flashes target the quoted support instead of a chunk lead sentence.
- Document AI citations now use calmer source titles, page-only labels for single-source answers, and collapse adjacent duplicate markers.
- Document AI answers now add quiet provenance notes, and stale PDF links explain why they cannot open.
- PDF citation links now open to the cited chunk and flash the matched passage when PDF text matching succeeds.
- Document AI answers over retrieved sources now turn model citation markers into PDF links.
- Document AI prompt popover now includes a session-only Sources scope chip for Auto, All, or None source context.
- Source rows now show quiet indexing status with retry for failed source indexing.
- Added local source chunk indexing foundations for Reading with Receipts.
- Selection popover now includes bold, italic, and inline-code markdown formatting controls.
- Selected stream text can now be linked to a picked PDF spot.
- PDF stream links now reopen their source and navigate back to the saved highlight.
- PDF pane with continuous scrolling and stream links back to selected highlights.
- Quick Panel ephemeral chats can save individual messages and clear the in-memory conversation.
- Quick Panel Save and AI + Save now append directly to stream documents, including live inserts into an open editor.
- Live markdown concealment and image widgets for a calmer document-writing surface.
- Revision-aware stream document saves to protect external appends from stale autosaves.

### Changed
- Editor font, size, and line-spacing defaults now use the same validation in app startup and Settings.
- The inactive ⌘; screenshot shortcut and its deprecated mode were removed; clipboard images still attach through ⌘L after a macOS screenshot.
- Release builds no longer bundle unused programming-language parsers or stale web assets from earlier builds.
- The main window, Quick Panel, and PDF pane now share the editor’s neutral surfaces and sienna accent, and Quick Panel names its background action “develop + save.”
- Delete, AI prompt, Search, Sources, and Exchange now share native modal behavior with contained focus, Escape and outside-click dismissal, and focus restoration.
- The selection toolbar now keeps common formatting and one AI entry in view, moves secondary actions behind disclosure, and fits alongside the link and provenance popovers at the 300 px window minimum.
- Stream lists now load bounded previews and cached word counts instead of transferring every document in full.
- Provenance spans now avoid unnecessary rehashing during edits and preserve distinct adjacent source attribution.
- Selection dragging in large documents now avoids repeated text extraction and dormant margin-note/find rescans.
- Large documents now avoid full-document React updates and editor reconfiguration on every keystroke, making typing more responsive.
- AI answers now fold the question's substance into their opening sentence so saved passages read complete on their own.
- The Claude model option is now marked "Coming soon"; AI requests route to the OpenAI models until it ships.
- Document AI now biases toward the only attached large source when a question has weak but present lexical overlap.
- Document AI now uses local source retrieval for large source sets instead of concatenating every source.
- Main window chrome is now transparent, with content inset around the floating traffic-light controls.
- Stream sources now open in a modal instead of a persistent sidebar, preserving editor width beside the PDF pane.
- PDF pane header controls now use compact icon toolbar styling and keep their hit targets with long source names.
- Stream editor, overlays, Quick Panel, and PDF pane now share a lower-chrome tokenized visual system.
- Bridge v2 is the live bidirectional document-model contract, routed through feature handlers with surfaced errors.

### Fixed
- Quitting immediately after an edit now waits briefly for the open editor to roll back temporary AI state and flush its latest text, with one bounded save retry.
- Queued editor saves now capture live text, provenance, and revision together instead of letting an older snapshot overwrite a newer external append.
- In-editor AI no longer autosaves temporary deletions or partial output, and leaving a stream mid-request restores the original passage before saving.
- Deleting a PDF link and autosaving no longer destroys its backing highlight, so Undo restores a working link.
- The editor header, stream list, dialogs, and selection disclosures now remain usable at the 300 px minimum window width, including very long titles.
- `ticker://append` now refuses ambiguous duplicate stream titles and directs reliable automation to the stream UUID instead of picking an arbitrary match.
- Search now includes source passages from every stream, including locally searchable sources marked Private for AI.
- Opening a PDF pane no longer overwrites the saved editor-only window frame; autosave resumes after the pane collapses.
- Quick Panel setup is now synchronous, deleted stream targets are discarded before saving, editor selection capture has a realistic timeout, and canceled chat turns leave no hidden partial response.
- Source-backed AI now performs local retrieval outside the main actor, keeping the window responsive during semantic query waits.
- Image imports now keep immutable unique assets, write atomically, reject oversized inputs before decoding, and prepare AI image context off the main thread.
- PDF attachments now extract text once in the background instead of blocking the main window and repeating the work during indexing.
- Literal Markdown entities now stay unchanged when editor context is sent to AI.
- Stream loading now has correlated failure states, and a database startup failure leaves Settings, diagnostics, and Quit available instead of trapping the app behind loading UI.
- AI context cleaning now removes only Ticker’s exact underline tags, preserving comparisons, generic types, and code-like angle brackets.
- Removing a source now cancels its queued or active indexing work first, and failed status writes stop after a bounded retry instead of recurring forever.
- Text, Markdown, and OCR image sources now build retrieval chunks instead of reporting ready with no searchable content.
- Quick Panel AI answers, provenance, and exchange receipts now save in one transaction instead of leaving partial history when a database write fails.
- Overlapping Quick Panel AI requests now keep independent activity state, failures no longer write operational text into notes, and external captures no longer occupy local editor Undo history.
- Source retrieval no longer treats one strong word shared with a multi-word question as sufficient lexical evidence.
- The PDF pane now follows the app's light/dark theme: page margins and pane backgrounds previously stayed light in dark mode, and opening/closing no longer warps the window across the screen — the pane and window frame animate together.
- The provenance-overlay popover now follows the hovered text and positions like the selection menu; it previously rendered cramped at the top-right of the stream regardless of the pointer.
- Device-key changes now report disk-write failures in Settings and leave the durable key and in-memory auth state unchanged.
- Source indexing can no longer remain stuck after terminal status-write failures, and refreshed file bookmarks now persist after stale recovery.
- Source-required AI requests now fail when local retrieval fails, while Auto answers clearly disclose retrieval degradation.
- Bridge callback failures now return immediately instead of timing out, and production surfaces a safe error when native actions fail.
- Quick Panel AI now clears the editor typing indicator and shows an error if its answer cannot be saved.
- Quick Panel now ignores late AI callbacks from a cancelled request after a new conversation request starts.
- Bridge sends now enforce the main-thread boundary, and overlapping document AI cancellation can no longer race its request registry.
- Database upgrades now stop before migration when the required safety backup cannot be created.
- Rapid stream navigation can no longer be overwritten by an older, slower stream load.
- Leaving a stream now flushes pending edits, stops in-flight document AI, and visibly reports save failures instead of remaining stuck on “Saving…”.
- Drag selection no longer stalls or lags in streams containing links: link chips were rebuilt on every selection tick during a drag, feeding CodeMirror's pointer snapping a moving target. Failed image loads now also record their real rendered size so scroll geometry stays honest.
- A revision-conflict reload during an in-flight AI request no longer risks replacing the entire stream with the AI passage: the request is cancelled and its writing range cleared before the document reloads.
- Search now speaks the document model: opening a result scrolls the stream to the matched text (previously errored on a defunct cell anchor), and searching from the stream list covers all streams instead of arbitrarily treating the first list entry as "current".
- Quick Panel typing dots now pulse while waiting for the first AI chunk instead of sitting static.
- Bug reports no longer falsely claim the previous session crashed after an app auto-update.
- Quick Panel now avoids copying an editor cursor line when Accessibility reports that no text is selected.
- Debug builds now use a distinct bundle id and display name so they do not share the release app's macOS permission identity.
- Bug report support bundles now include recent metadata logs, crash evidence, uptime, and prior-crash detection.
- Selection action menus now re-clamp after measuring so they stay inside the editor shell.
- PDF pane dividers can now resize both directions from the opening split.
- Quick Panel external text capture now falls back through app AX hinting and clipboard-safe Copy for Chromium/Electron selections.
- Formatting toggles now keep selection-edge whitespace outside inline markdown markers, including multi-line selections.
- Stream editor markdown decorations now settle on the initial viewport faster and image widgets report stable heights while scrolling.
- Stream editor find now uses a compact input/count/arrows panel instead of the stock search UI.
- PDF panes now support focused Cmd-F find with match highlights, wrapping navigation, and Escape dismissal.
- Quick Panel now fits expanded content, captures in-app editor/PDF selections, and confirms saves by flashing the stream picker.
- Citation page fallback now flashes the cited page, and the main window now uses normal app window stacking.
- Opening the PDF source pane now expands the window to a balanced split and restores the prior window frame on close.
- Citation clicks that fall back to page navigation now show a transient page-scoped affordance instead of landing silently.
- PDF citation flashes now verify quoted evidence against the stored source chunk before highlighting page text.
- PDF highlight navigation now centers the target marker or highlight in the pane.
- PDF anchor picking now shows a crosshair cursor, and deleting PDF links removes their saved markers.
- Restored window dragging from the transparent titlebar strip.
- Source access now recovers refreshed bookmarks when possible, PDF stream links keep accent styling, and PDF anchor picking cancels on outside click.
- Recovered quick-capture notes that previously didn't appear in streams.
- Restored Quick Panel selected-text context preview and blockquote saves.
- Stopped embedded stream images from flickering or refetching while editing nearby text, and made cursor movement skip image tokens atomically.
- Restored the stream editor selection action menu using CodeMirror selection state.
- Made Quick Panel dismissal consistent, stabilized stream picking, and added visible save feedback.

### Removed
- Client-side intent classification is fully retired: the proxy now offers the answering model a web-search tool, so the model decides when it needs live information.
- Smart routing no longer downloads a local MLX model; a deterministic keyword gate decides search vs. knowledge (the 0.5B classifier misclassified in live testing).
- Removed AI-generated margin notes (read-back and Challenge tension notes) and the margin-notes header toggle; margin rendering can no longer be enabled from the app.
- Removed dead TipTap/cell-era editor paths, legacy bridge messages, cell write/read paths, and unused LLM providers from active runtime.

## Versioning

Ticker uses `YYYY.MM.patch` (alpha), e.g. `2026.01.3`.
