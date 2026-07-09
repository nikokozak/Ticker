# Changelog

All notable user-facing changes to Ticker are documented here.

## Unreleased

### Added
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
- Document AI now biases toward the only attached large source when a question has weak but present lexical overlap.
- Document AI now uses local source retrieval for large source sets instead of concatenating every source.
- Main window chrome is now transparent, with content inset around the floating traffic-light controls.
- Stream sources now open in a modal instead of a persistent sidebar, preserving editor width beside the PDF pane.
- PDF pane header controls now use compact icon toolbar styling and keep their hit targets with long source names.
- Stream editor, overlays, Quick Panel, and PDF pane now share a lower-chrome tokenized visual system.
- Bridge v2 is the live bidirectional document-model contract, routed through feature handlers with surfaced errors.

### Fixed
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
- Removed dead TipTap/cell-era editor paths, legacy bridge messages, cell write/read paths, and unused LLM providers from active runtime.

## Versioning

Ticker uses `YYYY.MM.patch` (alpha), e.g. `2026.01.3`.
