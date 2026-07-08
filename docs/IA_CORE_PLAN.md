# Roadmap 4 — IA Core (provenance, verbs, dignity)

> **For agentic workers (Codex or similar):** Execute tasks strictly in order within a phase. One task = one commit.
> Before each task, restate the user-visible behavior change in one sentence. After each task, run the listed
> verification; do not start the next task while verification fails. Steps use checkbox (`- [ ]`) syntax.
> When this document and the code disagree on a line number, trust the code and the named symbol; when it disagrees
> on behavior or schema, STOP and ask the governor.

**Goal:** Ship the reviewed IA-core feature set: living auto-titles and short source names everywhere; a document
surface that never shows its plumbing; thought-verbs instead of a single replace action; the provenance layer
(sidecar spans, x-ray toggle, dissolve, exchange receipts, re-develop); grounded quick-panel answers; the sienna
aesthetic unification; invited marginalia; and shell polish. Design authority: the annotated review artifact
(`.lavish/ticker-ux-audit.html`) — this document is its executable form.

**Philosophy (governs every judgment call):** Ticker is IA — intelligence amplification — not an AI app. The
document, not the assistant, is the center. No chat UI anywhere. AI text fuses seamlessly into the document;
honesty is provided by *summonable* provenance, never by permanent decoration. Wrong provenance is worse than
none. Nothing silent.

---

## Locked decisions (do not re-litigate; deviations require governor approval)

| # | Decision |
|---|---|
| D1 | **The past is the past.** Prior AI exchanges are NEVER fed back as context. Every AI call remains one-shot: `priorCells: []` stays empty, forever. `ai_exchanges` rows exist for receipts (show-exchange) only and must never be injected into prompts. |
| D2 | **Two registers, one rule.** AI text *in* the document is injected as-is and carries a provenance span (fused register). AI voice *beside* the document (margin notes, Challenge) is quoted and never editable. No feature may invent a third register. |
| D3 | **Replace-in-place stays first-class.** Today's "Send" behavior is renamed **Develop** and keeps replacing. Appending verbs (Ask, Challenge, Define) are added beside it. |
| D4 | **X-ray and marginalia are toggles** (header buttons), not held-key modes. Zero provenance decoration when toggles are off. Any AI-marking styling must be whisper-subtle and strippable. |
| D5 | **Quick panel stays ephemeral.** Esc discards; per-message "keep" persists. No auto-persist. "Continue in stream" is deferred indefinitely (end-stage, not in this roadmap). |
| D6 | **Auto-titles are living until claimed.** Regenerate as the stream evolves; the moment the user manually renames, freeze forever. |
| D7 | **Accent = sienna `#a4502e`** (light mode). Dark-mode value starts at `#d98a63` and requires one human glance before the aesthetic phase is considered verified. |
| D8 | **Paste semantics:** paste out of Ticker leaks nothing (spans are sidecar); paste within a document drops provenance (moved text becomes the user's). Confirmed OK. |
| D9 | **Provenance is never inferred, only inherited.** Pre-existing text is the user's by definition. No backfill, no classifier, ever. |
| D10 | **Marginalia are invited-only** ("Read back" action), never ambient/automatic. Not editable. Promote / dismiss / open only. |
| D11 | All character offsets crossing the bridge are **UTF-16 code units** (CodeMirror's native unit). Swift MUST count with `String.utf16`. |

## Global constraints (unchanged from AGENTS.md / CLAUDE.md — restated)

- One data model: `stream_documents.markdown` (+ `revision`). Markdown stays pure — provenance lives in sidecar
  tables, NEVER as inline markers, HTML comments, or custom syntax in the document text.
- One external-write primitive: `appendToStreamDocument` + `streamDocumentAppended`.
- A feature = CM extension (web) + `BridgeMessageHandler` (Swift) + entries in `docs/contracts/bridge.v2.json`
  AND `Web/src/types/bridge.ts` — `node tools/contracts/check_bridge_contract.mjs` is CI-enforced and must pass
  after every bridge change.
- Migrations are append-only. As of writing the last migration is `v17_source_ai_exclusion`
  (`Sources/Ticker/Services/PersistenceService.swift`). This roadmap assigns: **v18** (P1), **v19** (P2),
  **v20** (P4), **v21** (P7). If other work lands migrations first, renumber to the next available — never edit
  an existing migration.
- Editor perf: CM plugins walk `view.visibleRanges` only.
- Build/verify gates: `./tickerctl.sh build-dev` · `./tickerctl.sh swift-test` ·
  `cd Web && npm run typecheck && npm test && npm run build` · `node tools/contracts/check_bridge_contract.mjs`.
- Real user data safety: copy `~/Library/Application Support/Ticker-Next/ticker.db` aside before driving the app;
  clean up test fragments. Two instances must never share the DB.
- AI apply = one undo step (existing invariant — every new AI path must preserve it).

---

## Phase P1 — Naming & re-entry

### Task 1.1: Short source titles everywhere

**Behavior change:** No surface ever shows a raw filename again; everywhere a source is named, the derived short
title appears (full filename available as tooltip/subtitle where the surface supports it).

`SourceShortTitle.derive(displayName:)` already exists (`Sources/Ticker/Models/SourceReference.swift`) and is used
for AI citations (`Sources/Ticker/App/Bridge/AIMessageHandler.swift`). Apply it to the remaining surfaces:

**Files:**
- `Sources/Ticker/App/PDFReader/PDFReaderPaneController.swift` — pane header title.
- `Sources/Ticker/App/QuickPanel/QuickPanelView.swift` / `QuickPanelManager.swift` — stream-picker rows and the
  collapsed pill (stream titles themselves are fixed by Task 1.2; sources shown anywhere in the panel use short titles).
- `Sources/Ticker/App/Bridge/StreamCodec.swift` — wherever source `displayName`/`name` is encoded for the web
  (sources list, search results), add a `shortTitle` field alongside the full name; do NOT remove the full name.
- `Sources/Ticker/App/Bridge/SourceMessageHandler.swift` + `SearchMessageHandler.swift` — include `shortTitle` in
  payloads if encoded there rather than in StreamCodec (grep `displayName` to find every encode site).
- Web: `Web/src/components/SourcesModal.tsx` (row title = shortTitle, full filename as a muted second line),
  `Web/src/components/SearchModal.tsx` (result titles), `Web/src/components/StreamEditor.tsx` (header “Sources · N”
  popover if it names sources).
- PDF highlight-link creation: grep for where the highlight link label is built (the markdown
  `[<label> p.N](ticker-pdf://…)` written on “Link Selection” — in `PDFReaderPaneController` or its callback in
  `WebViewManager`); use `SourceShortTitle.derive` for `<label>`.
- New-stream-from-PDF-drop titling (`WebViewManager.swift`, the drop path that titles a stream from a filename):
  use the short title.

**Steps:**
- [ ] Add `shortTitle` to every source-bearing bridge payload (contract + `bridge.ts` types updated together).
- [ ] Swap each UI surface listed above to render `shortTitle`, keeping the full name as tooltip (`title=` attr web,
      `toolTip` AppKit) or muted secondary line.
- [ ] Swift unit test: `SourceShortTitle.derive` on the canonical ugly case
      `"Forth Programmer's Handbook (3rd Edition) -- Edward K_ Conklin … -- Anna's Archive.pdf"` →
      `"Forth Programmer's Handbook (3rd Edition)"` (assert whatever the existing derivation actually returns — the
      test freezes current behavior; do not change derivation logic in this task).
- [ ] Verify: contract checker passes; build; open the app copy-DB-aside, confirm pane header / sources modal /
      search results / quick-panel picker all show short titles.
- [ ] Commit: `feat(naming): short source titles on every surface`

### Task 1.2: Living auto-titles (migration v18)

**Behavior change:** Untitled streams name themselves from their content and keep renaming as content evolves,
until the user renames manually — then the title never auto-updates again.

**Files:**
- `Sources/Ticker/Services/PersistenceService.swift` — migration + helpers.
- `Sources/Ticker/App/Bridge/StreamMessageHandler.swift` — hook points (`saveStreamDocument` case,
  `updateStreamTitle` case).
- `Sources/Ticker/Services/ProxyLLMService.swift` — reuse `generateRestatement(for:)` (returns ≤8-word heading
  or `nil`; 30s timeout; already exists at `:310`).
- Test: `Tests/TickerTests/StreamDocumentTests.swift`.

**Migration v18 (exact DDL):**
```sql
ALTER TABLE streams ADD COLUMN title_locked INTEGER NOT NULL DEFAULT 0;
ALTER TABLE streams ADD COLUMN auto_titled_at DOUBLE;          -- last auto-title time
ALTER TABLE streams ADD COLUMN auto_titled_length INTEGER;     -- doc length at last auto-title
ALTER TABLE streams ADD COLUMN source_scope TEXT NOT NULL DEFAULT 'auto';  -- used by Task 3.2
```
Backfill in the same migration: `UPDATE streams SET title_locked = 1 WHERE title IS NOT NULL AND title != ''
AND title != 'Untitled';` (existing custom titles are user-claimed; existing `Untitled` streams become living).

**Auto-title rules (implement exactly):**
1. `updateStreamTitle` (user rename path) sets `title_locked = 1`. Exception: if the new title is empty or
   `"Untitled"`, set `title_locked = 0` (user un-claims).
2. After a successful `saveStreamDocument` where `title_locked == 0`, schedule an auto-title if BOTH:
   (a) `auto_titled_at` is NULL or older than 120 seconds, AND
   (b) `abs(markdown.utf16.count − auto_titled_length ?? 0) ≥ 200` (content changed meaningfully) or title is
   empty/`Untitled`.
3. Auto-title = `generateRestatement(for: String(markdown.prefix(2000)))`; on non-nil, non-empty result:
   update `streams.title`, `auto_titled_at = now`, `auto_titled_length = markdown.utf16.count`, and send the
   existing `streamsChanged` notification so the list refreshes. On nil (offline/AI unavailable): do nothing,
   silently — never block or error the save path.
4. Debounce: at most one in-flight restatement per stream; drop, don't queue.

**Steps:**
- [ ] Migration + backfill; `swift-test` green (add migration test: fresh DB has columns; custom-titled stream
      backfills locked=1).
- [ ] Implement rules 1–4 in `StreamMessageHandler` (`saveStreamDocument` completion) as a small
      `AutoTitleService` (one file, `Sources/Ticker/Services/AutoTitleService.swift`, constructed in
      `ServiceContainer`). Do not call the proxy from `PersistenceService`.
- [ ] Unit tests: rule 1 lock/unlock; rule 2 thresholds (no-op under 200 delta; fires on first-ever save of an
      Untitled stream); rule 4 single-flight (inject a mock restatement provider — add a
      `protocol RestatementProviding { func restate(_ s: String) async -> String? }` conformed by
      `ProxyLLMService`, mocked in tests).
- [ ] Web: no changes needed (title arrives via existing summaries/`streamLoaded`) — but verify the editor's
      editable title doesn't clobber a fresh auto-title on blur without user edits (grep the title-blur handler in
      `StreamEditor.tsx`; only send `updateStreamTitle` when the field text actually changed from the loaded value).
- [ ] Verify live (copy DB aside): create stream via quick panel, type a paragraph, wait for save + title; rename
      manually → never auto-renames again.
- [ ] Commit: `feat(streams): living auto-titles, frozen on manual rename (v18)`

### Task 1.3: Stream list — search, previews, human units

**Behavior change:** ⌘K works from the stream list; every stream card shows a one-line content preview; counts are
words, not chars.

**Files:**
- `Web/src/App.tsx` — mount `SearchModal` at App level (it currently mounts only inside `StreamEditor.tsx:~1841`);
  a `⌘K` keydown listener at App level opens it in both `list` and `stream` views (keep the existing one in the
  editor working or lift it entirely — lift, don't duplicate).
- `Web/src/components/SearchModal.tsx` — when opened from the list view, `onNavigateToStream` switches view to the
  stream (the App-level open needs the same navigation props the editor passes today).
- `Sources/Ticker/App/Bridge/StreamCodec.swift` `encodeSummaries` — add `previewLine` (first non-empty,
  non-heading, non-image line of the markdown, stripped of markdown marks — implement `StreamCodec.previewLine(from:)`
  with unit tests: strips `#`, `*`, `>`, `[label](url)` → `label`, `![…](…)` → skipped) and `wordCount`
  (whitespace-split count). Keep `charCount` in the payload for compatibility; the web stops displaying it.
- `Web/src/App.tsx` stream card renderer — show preview line under the title (single line, CSS `-webkit-line-clamp: 1`),
  metadata line becomes `2d ago · <sourceShortTitle|N sources> · N words` (+ image count if > 0).

**Steps:**
- [ ] Contract: `hybridSearch` already exists web→swift; no new messages. Summaries payload gains fields —
      update `bridge.v2.json` if summaries payload shape is contract-tracked (check the contract file; if
      `streamsLoaded` payload is specified there, extend it).
- [ ] `previewLine` unit tests (Swift) with the markdown-stripping cases above.
- [ ] Verify live: list shows previews and word counts; ⌘K from list opens search; selecting a result opens the stream.
- [ ] Commit: `feat(list): global search, content previews, word counts`
- [ ] NOTE: do NOT add an “open questions” badge in this task — it depends on P7 (margin notes). The card is
      title + preview + metadata only.

---

## Phase P2 — Document dignity (migration v19)

### Task 2.1: The open moment — position restore + conceal pre-paint

**Behavior change:** A stream opens at the top the first time and at your last scroll position thereafter, with
markdown already concealed — raw `##`/`**`/URLs are never the first frame.

**Migration v19 (exact DDL):**
```sql
ALTER TABLE stream_documents ADD COLUMN scroll_offset REAL NOT NULL DEFAULT 0;
ALTER TABLE sources ADD COLUMN last_page_index INTEGER;   -- used by Task 2.3
```

**Files:**
- `Sources/Ticker/Services/PersistenceService.swift` — v19 + `func saveScrollOffset(streamId:offset:)`,
  offset persisted with the document row (no revision bump — it is not content).
- `Sources/Ticker/App/Bridge/StreamMessageHandler.swift` — `streamLoaded` payload gains `scrollOffset`; new
  web→swift message `saveScrollPosition { streamId, offset }` (fire-and-forget, debounced web-side 1s).
- `Web/src/components/StreamEditor.tsx` — on mount: after the editor view is created, (1) run
  `ensureSyntaxTree(state, viewportEnd, 50)` for the restore-target viewport BEFORE removing a mount-time
  `visibility:hidden` style on the editor container (add/remove a CSS class, e.g. `cm-prepaint`), (2) scroll to
  `scrollOffset` via `view.scrollDOM.scrollTop = offset` (0 for first open), (3) reveal. The editor must never
  paint unconcealed text: the reveal happens in a `requestAnimationFrame` after the first decoration pass.
- `Web/src/extensions/MarkdownConceal.ts` — verify its initial-parse timeout (20ms) is not the reveal gate;
  the gate lives in StreamEditor. Do not modify conceal logic.

**Steps:**
- [ ] Migration + persistence helpers + tests (offset save/load round-trip; save does NOT bump `revision`).
- [ ] Bridge: `saveScrollPosition` added to `bridge.v2.json` + `bridge.ts` (WEB_TO_SWIFT list); `streamLoaded`
      payload documented with `scrollOffset`.
- [ ] Web implementation as specified; debounce scroll saves 1s; also save on unmount/stream switch.
- [ ] Verify live: open a long stream mid-scroll, quit, relaunch, reopen → same position, zero raw-markdown flash
      (screenshot the first frame: drive with the verify skill, `screencapture` immediately after load).
- [ ] Commit: `fix(editor): conceal pre-paint + scroll position restore (v19)`

### Task 2.2: Link interaction — navigate on click, edit via popover

**Behavior change:** Clicking any link navigates. Putting the cursor in a link no longer explodes it into raw
markdown; a small popover offers label/URL editing. ⌥-click reveals raw markdown (power path).

**Files:**
- `Web/src/extensions/MarkdownConceal.ts` — change the active-line reveal rule for link nodes ONLY: when the
  selection line intersects a `Link` node, keep `LinkMark`/`URL`/`LinkTitle` concealed (today they reveal).
  Implementation: the existing `LINK_CONCEAL_NODE_NAMES` handling (`:6`, `:93`) currently participates in the
  "reveal on selection line" exemption — exclude link nodes from that exemption unless a new
  `revealRawLinks` state effect is active for that line (set by ⌥-click, cleared on selection leaving the line).
- New extension `Web/src/extensions/LinkInteraction.ts`:
  - Plain click on a rendered link: `http(s)://` → send new bridge message `openExternalURL { url }`;
    `ticker-pdf://` → existing `PDFHighlightLink.ts` behavior (do not duplicate — ensure ordering so the existing
    handler wins for ticker-pdf).
  - Cursor placed inside a link via keyboard, or click-with-cursor-already-inside: show a link popover
    (reuse the selection-menu surface pattern in `StreamEditor.tsx` — same tokens, same placement util
    `selectionMenuPlacement.ts`) with two inputs (label, URL) + `Unlink` + `Remove`. Commit on Enter/blur:
    dispatch a change replacing the link range with the edited `[label](url)`.
  - ⌥-click: dispatch the `revealRawLinks` effect for that line.
- Swift: `openExternalURL` case in `Sources/Ticker/App/Bridge/StreamMessageHandler.swift` (or a small
  `ShellMessageHandler`) → `NSWorkspace.shared.open(url)` with `http/https` scheme allow-list ONLY (reject
  everything else, log via `DebugLog`).
- Contract: add `openExternalURL` (web→swift).

**Steps:**
- [ ] Implement; vitest for the popover commit logic (pure function: `(oldRange, label, url) → change spec`) and
      for scheme allow-listing (unit test the guard as a pure function web-side too — belt and suspenders).
- [ ] Verify live: click http link → browser opens; click citation → PDF pane (unchanged); cursor into a link →
      popover, edit label → document updates without ever showing the URL-encoded string; ⌥-click → raw markdown.
- [ ] Commit: `feat(editor): link navigation + popover editing; raw markdown only on demand`

### Task 2.3: Reading dignity — resume, outline, words not beeps

**Behavior change:** PDFs reopen where you left them; a table-of-contents sidebar exists when the PDF has an
outline; every pane failure states its reason in words.

**Files:** `Sources/Ticker/App/PDFReader/PDFReaderPaneController.swift`, `PersistenceService.swift` (uses
`sources.last_page_index` from v19), pane header UI.

**Steps:**
- [ ] Persist `last_page_index` on page change (debounced 2s, via `PDFView.currentPage` index); on
      `present(url:…)` WITHOUT an explicit destination (citation clicks pass destinations — those still win),
      navigate to the saved page after document load.
- [ ] Outline: if `pdfDocument.outlineRoot != nil`, add a header toolbar button (SF Symbol `list.bullet`) toggling
      a left sidebar (~220pt, resizable not required) listing outline entries (indent by depth, max depth 3);
      click → `pdfView.go(to: destination)`. No outline → no button.
- [ ] Replace every `NSSound.beep()` in the pane with the existing status/text affordance pattern (grep
      `NSSound.beep` — each site gets a short human string, e.g. “Nothing is selected to link”, shown the same way
      the find bar shows its counter, or via the pane header subtitle for 2.5s).
- [ ] Verify live: open 274-page PDF, scroll to p. 118, close pane, reopen source → p. 118; outline sidebar
      navigates; trigger a beep-site (e.g. Link with no selection) → text appears, no beep.
- [ ] Commit: `feat(pdf): resume position, outline sidebar, spoken failures`

---

## Phase P3 — Verbs & prose

### Task 3.1: Prompt rewrite — document prose, not bot output

**Behavior change:** AI contributions read as document prose; the bolded-term bullet wall disappears.

**Files:** `Sources/Ticker/Services/Prompts.swift` (`thinkingPartner`, `thinkingPartnerWithHeading`).

Replace the body of `thinkingPartner` with EXACTLY this (adjust only if the citation-instruction suffix from
`AIOrchestrator.swift:~230` composes after it — keep that mechanism untouched):

```
You are contributing text to the user's research document. Your output is inserted directly
into their notes and must read as part of the document — never as a chat reply.

Rules:
- Write flowing prose paragraphs. No greetings, no framing ("Here is…", "Certainly"), no
  closing summary, no offers of further help.
- Use a heading or a list ONLY when the content is genuinely enumerable (steps, ingredients,
  API fields). Never use lists as the default shape. Never produce lists of bolded
  term-colon-definition pairs.
- Be concrete and specific. No filler, no hedging, no restating the question.
- Match the surrounding document's tone and terminology when context is provided.
```

`thinkingPartnerWithHeading`: same body + the existing first-line `## Heading` requirement sentence.

**Steps:**
- [ ] Replace prompts; grep for other callers of `thinkingPartner` to confirm blast radius (quick panel ⌘↵ uses the
      document path — intended).
- [ ] Verify live with a real AI round-trip (copy DB aside): ask the pasta question in a scratch stream — output
      must be prose, no `**Term**:` bullets. Clean up the fragment after.
- [ ] Commit: `feat(prompts): document-prose style for all document AI`

### Task 3.2: The verb menu — Ask · Challenge · Define · Rewrite▾, scope visible, stop button

**Behavior change:** The selection menu offers thought-verbs; only Rewrite▾Develop replaces text and says so;
the source-scope chip is visible for every AI action; a running request can be stopped.

**Files:**
- `Web/src/components/StreamEditor.tsx` — selection menu (`:~1680-1758`), keyboard wiring (`:~1453-1473`),
  AI dispatch (`startDocumentAI`), status pill.
- `Sources/Ticker/Services/Prompts.swift` — verb prompts (below).
- `Sources/Ticker/App/Bridge/AIMessageHandler.swift` — `verb` passthrough + cancellation.
- Contract + `bridge.ts`: `thinkDocument` payload gains `verb` (string enum `develop|ask|challenge|define`,
  default `develop` when absent); new web→swift `cancelDocumentAI { requestId }`; document these.
- `Sources/Ticker/Services/SettingsService.swift` is NOT involved; scope persistence uses `streams.source_scope`
  (v18): new handling in `StreamMessageHandler` — `streamLoaded` carries `sourceScope`, and the existing scope
  cycle control sends new web→swift `setSourceScope { streamId, scope }`. Delete the in-memory
  `sourceScopeByStreamId` Map (`StreamEditor.tsx:80`).

**Menu layout (order matters):** `Ask · Challenge · Define │ Rewrite ▾ │ B · I · </>`.
`Rewrite ▾` opens a one-item submenu for now: `Develop (replaces)`. ⌘↩ keeps its muscle-memory meaning = Develop
on selection (falls back to cursor paragraph, existing `getSelectionContext(true)` behavior). ⌘⇧↩ = Ask with the
prompt popover (append mode). Menu buttons show no icons — text labels only, existing button styles.

**Verb behaviors:**
| Verb | Mode | Output placement | Prompt (Prompts.swift, add as `verbAsk` etc.) |
|---|---|---|---|
| Develop | replace (today's Send, unchanged pipeline) | in place | `Develop the following passage into a fuller, clearer version of the same idea. Preserve the author's voice and intent; deepen, do not pad. Output only the developed passage.` |
| Ask | append after selection (today's Send & Prompt `after` mode) | below selection | `Answer the question or continue the line of thought, grounded in the provided context. Output only the answer prose.` |
| Challenge | append after selection, **quoted register**: web wraps the completed output as blockquote lines (`> ` prefix per line) + trailing line `*— Challenge*` | below selection | `Identify the single weakest point in this passage — a hidden assumption, an internal contradiction, or an unsupported leap. State it plainly in two to four sentences, then end with one pointed question back to the author. Do not rewrite the passage. Do not answer your own question.` |
| Define | append after selection | below selection | `Define or explain the selected term or phrase concisely, in the context of the surrounding document. Two to four sentences. Output only the explanation.` |

All verbs go through the single `thinkDocument` funnel; `AIMessageHandler` selects the verb prompt as the system
prompt (composed with the existing citation instructions exactly as `thinkingPartner` is today). D1: `priorCells`
stays `[]`.

**Scope chip:** render the existing `Sources: Auto/All/None` cycle control in the selection menu itself (compact,
rightmost) AND keep it in the prompt popover. It reads/writes `streams.source_scope` via the new message; the value
arrives with `streamLoaded`.

**Stop button:** while `isAiThinking`, the status pill (“AI is writing”) gains a `Stop` affordance (small ✕ text
button). Click → `cancelDocumentAI { requestId }`. Swift: `AIMessageHandler` keeps `[String: Task<Void, Never>]`
of in-flight requests; cancel → `task.cancel()`, then send `documentAIError { requestId, errorCode: "cancelled" }`.
Web: on `errorCode === "cancelled"`, restore `originalText` exactly as other errors do, but show NO toast and no
error pill. `ProxyLLMService` streaming loop must check `Task.isCancelled` between chunks (verify it already
propagates cooperative cancellation; if not, add the check in the chunk loop).

**Steps:**
- [ ] Prompts + verb plumbing + contract updates (checker green).
- [ ] Scope persistence (v18 column already exists) — delete the Map, round-trip test: cycle scope, reload stream,
      scope persists.
- [ ] Challenge quoted-register wrapping: vitest on the pure wrapper `(text) → "> …\n> …\n\n*— Challenge*"`
      including multi-paragraph output.
- [ ] Cancellation: Swift test with a mock provider that streams slowly — cancel mid-stream → task ends, error sent
      with `cancelled`; web vitest: cancelled error restores text silently.
- [ ] Verify live: all four verbs on a scratch stream (real round-trips), one-⌘Z undo for each, Stop mid-stream
      restores the selection. Clean up fragments.
- [ ] Commit: `feat(ai): thought-verbs, persistent visible scope, stop control`
- [ ] NOTE (D2/P7 dependency, write in code comment at the Challenge wrapper): `// Challenge renders inline-quoted
      until margin notes ship (Roadmap 4 P7); then it becomes a margin note. ponytail: inline placement is the ceiling here.`

---

## Phase P4 — The provenance layer (migration v20)

The platform investment. Read `.lavish/ticker-ux-audit.html` §7 before starting. Order within the phase is strict.

### Task 4.1: Schema + hashing + offset discipline

**Migration v20 (exact DDL):**
```sql
CREATE TABLE provenance_spans (
  span_id     TEXT PRIMARY KEY,
  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
  start       INTEGER NOT NULL,          -- UTF-16 code units into stream_documents.markdown
  end         INTEGER NOT NULL,          -- exclusive
  origin      TEXT NOT NULL,             -- 'ai' | 'source' | 'capture'
  request_id  TEXT,                      -- ai origin: links to ai_exchanges
  source_id   TEXT,                      -- source origin
  meta        TEXT NOT NULL DEFAULT '{}',-- JSON: model, page, sourceApp, parent_request_id
  text_hash   TEXT NOT NULL,             -- FNV-1a 32-bit hex of covered text (see below)
  created_at  DOUBLE NOT NULL
);
CREATE INDEX idx_prov_stream ON provenance_spans(stream_id);

CREATE TABLE ai_exchanges (
  request_id  TEXT PRIMARY KEY,
  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
  verb        TEXT NOT NULL,
  user_input  TEXT NOT NULL,             -- selection + typed prompt, labeled, plain text
  source_manifest TEXT NOT NULL DEFAULT '[]',  -- JSON array as built for citations
  response_raw TEXT NOT NULL,            -- pre-citation-swap model output
  model       TEXT,                      -- from documentModelSelected
  created_at  DOUBLE NOT NULL
);
```

**Hash algorithm (MUST be byte-identical in Swift and TypeScript — include the shared test vector):**
FNV-1a 32-bit over the UTF-8 bytes of the covered text, rendered as 8-char lowercase hex.
Test vector: `fnv1a("The quick brown fox") == "048fff90"` — hard-code this exact assertion in BOTH a Swift test and
a vitest; if it fails, the implementation is wrong, not the vector.
```
hash = 0x811c9dc5
for byte in utf8(text): hash = (hash XOR byte) * 0x01000193  (mod 2^32)
```

**Offset discipline (D11):** every `start`/`end` in the DB and on the bridge is UTF-16 code units. Swift helpers
(new file `Sources/Ticker/Models/ProvenanceSpan.swift`):
```swift
struct ProvenanceSpan: Codable, Equatable { … }   // fields mirroring the table
enum UTF16Offsets {
    static func substring(_ s: String, start: Int, end: Int) -> String?  // nil if out of range
    static func utf16Length(_ s: String) -> Int
}
```
`substring` MUST index via `s.utf16.index` — never `String.Index` arithmetic on characters.

**PersistenceService additions:**
```swift
func loadSpans(streamId: UUID) throws -> [ProvenanceSpan]
func replaceSpans(streamId: UUID, spans: [ProvenanceSpan]) throws       // full-set replace, same txn pattern as saves
func loadExchange(requestId: String) throws -> AIExchange?
func saveExchange(_ exchange: AIExchange) throws
func deleteOrphanExchanges(streamId: UUID) throws  // exchanges with no remaining span referencing request_id
```

**Steps:**
- [ ] Migration, models, helpers.
- [ ] Tests: migration; FNV-1a vector (Swift); UTF-16 substring with the string `"a🙂b"` — `utf16Length == 4`,
      `substring(start: 3, end: 4) == "b"` (this is the emoji-shift regression test; a grapheme-counting
      implementation returns `"b"` for start 2 and fails); spans CRUD round-trip; cascade delete with stream.
- [ ] Commit: `feat(provenance): spans + exchanges schema, shared hash, UTF-16 discipline (v20)`

### Task 4.2: Bridge plumbing — spans travel with the document

**Contract changes (all four together: `bridge.v2.json`, `bridge.ts`, Swift senders, web handlers — checker green):**
- `streamLoaded` payload: add `spans: ProvenanceSpanJSON[]`
  (`{spanId, start, end, origin, requestId?, sourceId?, meta, textHash, createdAt}`).
- `saveStreamDocument` (web→swift) payload: add `spans: ProvenanceSpanJSON[]` — the full current set; Swift
  `replaceSpans` inside the SAME transaction as the markdown save, only when the revision check passes.
- `streamDocumentAppended` payload: add `spans: ProvenanceSpanJSON[]` — spans for the appended fragment, with
  offsets already absolute (Swift computes: `existingLength(utf16) + separator + fragment-relative`).
- `streamDocumentConflict` reload: web must replace BOTH text and spans from the payload — add `spans` there too.
- New web→swift `getExchange { requestId }` → callback `{exchange: {...} | null}`.

**Steps:**
- [ ] Swift: `StreamMessageHandler` save path (spans validated: in-bounds, start<end, hash matches the saved
      markdown — invalid spans are DROPPED server-side with a `DebugLog` count, never an error to the user).
- [ ] Web: `bridge.ts` types; vitest for the span JSON (de)serialization helper.
- [ ] Contract checker green; `swift-test` green (save-with-spans revision-conflict test: stale save rejected →
      spans unchanged).
- [ ] Commit: `feat(bridge): provenance spans travel with document text`

### Task 4.3: `ProvenanceField` — the CM extension (state only, no UI)

**File:** `Web/src/extensions/ProvenanceField.ts` (+ `.test.ts`).

```ts
export interface Span { spanId: string; start: number; end: number; origin: 'ai'|'source'|'capture';
  requestId?: string; sourceId?: string; meta: Record<string, unknown>; textHash: string; createdAt: number }
export const setSpans      = StateEffect.define<Span[]>();        // full replace (load/conflict)
export const addSpans      = StateEffect.define<Span[]>();        // AI completion / append echo
export const dissolveSpans = StateEffect.define<string[]>();      // spanIds
export const provenanceField: StateField<Span[]>;
export function currentSpans(state: EditorState): Span[];
```
Rules (implement exactly):
1. On every transaction with `docChanged`: map each span's `start`/`end` through `tr.changes`
   (`assoc` −1 for start, +1 for end so insertions AT the boundary fall OUTSIDE the span — user text at a span
   edge is the user's).
2. An insertion strictly INSIDE a span splits it: two spans, same `requestId`/origin/meta, new `spanId`s
   (`crypto.randomUUID()`), `textHash` recomputed for each half from the post-change doc.
3. A span whose mapped length becomes `< 3` UTF-16 units is dropped (mechanical sliver rule).
4. Adjacent spans (gap 0) with identical `requestId` and origin merge on save-serialization (implement as an
   exported pure `normalizeSpans(spans, doc)` used by the autosave path — merging recomputes hash).
5. `dissolveSpans` and `addSpans` are registered with `invertedEffects` (from `@codemirror/commands`) so ⌘Z
   restores dissolved spans and undoing an AI apply removes its spans. (The existing AI apply is a single history
   entry — attach `addSpans` to that same transaction in Task 4.4 so inversion is automatic.)
6. `textHash` recompute uses the shared FNV-1a (import a tiny `Web/src/utils/fnv1a.ts` with the test vector).

Autosave integration (`StreamEditor.tsx`): the 350ms save now sends
`{streamId, markdown, baseRevision, spans: normalizeSpans(currentSpans(state), doc)}`. Load/conflict paths dispatch
`setSpans` with payload spans (after client-side hash check: drop mismatches silently — same rule as server).

**Steps:**
- [ ] Implement field + pure helpers; vitests: split-on-insert (insert mid-span → two spans, hashes correct);
      boundary-insert stays outside; delete-across shrinks; sliver drop; merge normalization; dissolve+undo
      restores; property test — 200 random edits over a doc with 5 spans, invariant: every surviving span's hash
      matches its covered text.
- [ ] Wire into StreamEditor (extensions array AFTER conceal; no visual output yet).
- [ ] Commit: `feat(editor): ProvenanceField — spans map through edits, ride undo`

### Task 4.4: Spans are born at write time

**Behavior change (invisible until 4.5):** every AI application and every external append creates spans; every
document AI completion records an exchange.

**Files:** `StreamEditor.tsx` (AI complete handler), `AIMessageHandler.swift`, `QuickPanelManager.swift`.

- Web, on `documentAIComplete` (inside the existing single-history-entry apply): compute the final inserted range
  (post-citation-swap text) → dispatch `addSpans([{origin:'ai', requestId, meta:{model, verb}, …}])` in the SAME
  transaction as the insert. The citation links inside the AI text stay part of the one ai span (no nested source
  spans in v1 — the manifest in the exchange carries the grounding).
- Swift, `AIMessageHandler`: on completion, `saveExchange` (verb, user_input = selection + prompt labeled
  `Selection:\n…\n\nPrompt:\n…`, manifest JSON as already built, response_raw = pre-swap text, model = value
  captured from the `documentModelSelected` send — store it on the in-flight request context). `thinkDocument`
  payload gains optional `parentRequestId` (for 4.6) → stored in exchange + span meta.
- Swift, `QuickPanelManager` / append path: `appendToStreamDocument` gains an optional
  `spans: [FragmentSpan]` parameter (`FragmentSpan = {relativeStart, relativeEnd, origin, sourceId?, meta}`,
  offsets relative to the fragment, UTF-16). The quick-panel fragment builder marks: captured selection/clipboard
  text + attribution line → `origin:'capture'` with `meta.sourceApp`; ⌘↵ AI response fragment → `origin:'ai'`
  + requestId (and its exchange row). User-typed note text gets NO span. `streamDocumentAppended` carries the
  absolute-offset spans (4.2); the open editor's append handler dispatches `addSpans`.

**Steps:**
- [ ] Implement; Swift tests: append-with-spans persists absolute offsets correctly INCLUDING when the existing
      document ends with an emoji (UTF-16 test); exchange saved on ⌘↵.
- [ ] Web vitest: complete-handler creates a span exactly covering the inserted text; ⌘Z removes text AND span.
- [ ] Verify live: capture into an open stream; check DB: `SELECT origin, start, end FROM provenance_spans` rows
      appear; undo an AI develop → spans table (after next save) has no orphan. Clean up.
- [ ] Commit: `feat(provenance): spans born at AI apply and external append; exchanges recorded`

### Task 4.5: X-ray toggle, tints, hover card, dissolve

**Behavior change:** A 👁 toggle in the editor header reveals provenance as subtle tints; hovering a span shows
origin/model/date and actions; dissolve works; toggling off removes every trace.

**Files:** `Web/src/extensions/ProvenanceXray.ts` (new), `StreamEditor.tsx` (header button + state),
`Web/src/styles/index.css` (tokens only).

- Toggle state: React state per open stream (not persisted). Header button placement: left of “Sources · N”.
- Decorations (only when toggle on): `Decoration.mark` with classes `cm-prov-ai` / `cm-prov-source` /
  `cm-prov-capture`, built from `provenanceField` over `view.visibleRanges` ONLY. Skip ranges covered by atomic
  image widgets. CSS (light+dark): background `--prov-ai-soft` = accent at 8% alpha, `--prov-source-soft` =
  warning-soft, `--prov-capture-soft` = success-soft; plus `border-bottom: 1px dotted` at 45% alpha of the same hue.
  No layout shift: no padding, no margin, no font changes.
- Hover card: `hoverTooltip` (only active while toggle on) → tooltip DOM (tokens: surface-raised, border, radius,
  control-shadow) showing: origin line (`Developed with <model> · <relative date>` / `Captured from <app>` /
  `From <source shortTitle>`), then action row: `dissolve` · `show exchange` (ai + requestId only) ·
  `re-develop` (per 4.6 gating) · `open source →` (source origin). Actions are plain accent text buttons.
- Dissolve: dispatches `dissolveSpans([spanId])`; selection-dissolve: if toggle on and a selection exists, the
  selection menu gains one extra item `Dissolve` that dissolves all spans intersecting the selection.
- While the x-ray toggle is on, editing stays fully enabled (it is a lens, not a mode).

**Steps:**
- [ ] Implement; vitest for decoration builder (spans → ranges, visible-ranges clipping, widget skip).
- [ ] Verify live: develop a passage, toggle x-ray → tint; hover → card; dissolve → tint gone, ⌘Z → back;
      toggle off → pristine document; type inside a tinted span with x-ray on → split visible immediately.
- [ ] Screenshot light + dark for the governor.
- [ ] Commit: `feat(editor): provenance x-ray toggle, hover card, dissolve`

### Task 4.6: Show exchange + re-develop

**Behavior change:** From a span's hover card you can open the receipt (what you asked, what was consulted, what
the model returned) and re-run the verb with the prompt shown first.

**Files:** `Web/src/components/ExchangeOverlay.tsx` (new), `StreamEditor.tsx`, `AIMessageHandler.swift`
(`getExchange` case from 4.2).

- Show exchange: hover-card action → `sendAsync('getExchange', {requestId})` → overlay (SearchModal surface
  language: same scrim, radius, shadow) with three labeled blocks: **You** (`user_input`), **Consulted**
  (manifest entries as `shortTitle p.N` links → existing `openPdfDestination` bridge path), **Model returned**
  (`response_raw`, rendered as plain pre-wrap text). Footer: `re-develop` · `copy raw` · Esc. If exchange is null →
  the hover card shows disabled text “exchange no longer stored” instead of the action (fetch once on card open).
- Re-develop gating: origin `ai`, span length ≥ 3 words (split on whitespace of covered text), no request in flight.
- Re-develop flow: opens the existing prompt popover pre-filled with the original prompt (from
  `user_input`'s Prompt section; empty if the verb had none) and a preview line “will replace: ‘<first 60 chars>…’”.
  Confirm → `thinkDocument` with `verb: 'develop'` (or original verb), `mode: replace` over the span's CURRENT
  range, `parentRequestId: <old requestId>`. Completion creates the new span (4.4) — lineage lands in meta.
- Exchange GC: after a save where spans were replaced, Swift calls `deleteOrphanExchanges(streamId:)`.

**Steps:**
- [ ] Implement; Swift test for `getExchange` round-trip + orphan GC; vitest for the re-develop gating pure function.
- [ ] Verify live: full loop — develop → x-ray → show exchange (links open the PDF pane) → re-develop with edited
      prompt → new text + new span whose meta carries `parent_request_id`; ⌘Z restores the old text AND old span.
- [ ] Commit: `feat(provenance): exchange receipts and re-develop with lineage`

---

## Phase P5 — Quick panel: grounded answers

### Task 5.1: ⌥↵ sees the picked stream's sources

**Behavior change:** Panel answers cite the picked stream's sources exactly like the editor; panel stays ephemeral.

**Files:** `Sources/Ticker/App/QuickPanel/QuickPanelManager.swift` (`handleOptionEnter`, the `streamId: nil` at
`:~547`), `AIOrchestrator.swift` (no change expected — it already routes retrieval when streamId is present).

- Pass the picked stream's real id instead of `nil`. Scope: the stream's persisted `source_scope` (v18).
- Citation markers in the panel: the panel renders text, not markdown. Swift-side, after completion, run the SAME
  marker swap used for documents (the manifest is in hand) but emit plain labels `(<shortTitle> p.N)` instead of
  links for panel DISPLAY, while the message kept via “keep” (save-to-stream) gets the full markdown link form.
  Implement as two render modes of one swap function — do not fork the marker parsing.
- D1 reminder: the ephemeral conversation's own turns (`priorCells` from `ephemeralConversation.turns`) are the
  ONE permitted multi-turn context (it is a live conversation the user is currently having, not resurrected past);
  do not remove it. Do not add document/exchange history.

**Steps:**
- [ ] Implement; unit test the dual-mode swap (label vs link) on the same manifest.
- [ ] Verify live: pick the Forth stream, ⌥↵ ask a book question → answer with `(Forth Handbook p.N)` labels;
      “keep” one message → stream gets the link form; Esc → nothing else persisted.
- [ ] Commit: `feat(quickpanel): source-grounded ephemeral answers`

---

## Phase P6 — Aesthetic unification

One task per bullet; each is styling-only (no behavior). Screenshot light+dark after each for the governor.
All in `Web/src/styles/index.css` unless noted.

### Task 6.1: Sienna + duration/radius/scrim tokens
- [ ] `--accent: #a4502e`, `--accent-hover: #8a3f22`, `--accent-soft: rgba(164,80,46,0.10)`,
      `--focus-ring: rgba(164,80,46,0.18)`. Dark block (`@media (prefers-color-scheme: dark)` section at
      `index.css:~2487`): `--accent: #d98a63` (+ derived soft/hover) — **flag for the user's dark-mode glance in
      the PR description (D7)**.
- [ ] New tokens: `--radius-small: 4px` (apply to icon chips, toast close, badges — grep 20/22px controls);
      `--duration-fast: 120ms`, `--duration-base: 200ms` — replace every ad-hoc transition duration;
      `--overlay-scrim: rgba(31,31,29,0.45)` (up from 0.34) and ensure SourcesModal/SearchModal actually render a
      scrim element using it.
- [ ] Commit: `style: sienna accent + duration/radius/scrim tokens`

### Task 6.2: Type scale with real hierarchy
- [ ] `--editor-heading-1: 1.6em`, `--editor-heading-2: 1.35em`, `--editor-heading-3: 1.15em`; heading weights
      650/600/600 (integers that exist in SF Pro; delete the fractional 620–650 grades in
      `StreamEditor.tsx` `markdownHighlightStyle` — move sizes/weights fully into CSS if currently split).
      Letter-spacing −0.015em on h1, −0.01em on h2.
- [ ] Commit: `style: heading scale that reads as hierarchy`

### Task 6.3: One button rule — black acts, accent is AI
- [ ] Audit every button: primary actions (New Stream, Save Key, Done, Add Source) = `--text` background
      near-black style; AI-invoking actions (verb menu, prompt Send) = accent. Remove the `!important` overrides
      in `.settings-button` (`index.css:~220-229`) by fixing specificity properly.
- [ ] Commit: `style: one primary-button rule (black = act, sienna = AI)`

### Task 6.4: Iconography + dialogs
- [ ] Replace emoji glyphs (📝 empty state, 🔑 auth, ⏳ spinner, 📄/🖼/📎 file types, ✦/✨ badges) with a small
      inline-SVG set in `Web/src/components/icons.tsx` (single file, 16/20px stroke icons, `currentColor`).
      Toast close becomes an SVG ×. One spinner (CSS border-spin) everywhere; delete the duplicate
      `@keyframes spin`.
- [ ] Replace both `alert()` calls in `Settings.tsx` (`:~242,246`) with the existing toast system.
- [ ] Commit: `style: one icon vocabulary; no emoji chrome, no alert()`

### Task 6.5: Code styling + snippet hygiene + arrival motion
- [ ] Inline code: `background: var(--surface); padding: 1px 5px; border-radius: var(--radius-small)`.
      Fenced blocks: `background: var(--surface)` full-line via a conceal-layer line decoration
      (`MarkdownConceal.ts` already walks fenced nodes — add a `cm-codeblock-line` class), hairline border.
- [ ] `SearchModal` snippets: strip markdown marks before display (reuse/port the `previewLine` stripping from
      Task 1.3 as a web util with vitest).
- [ ] Arrival animation: appended fragments (the `streamDocumentAppended` insert in `StreamEditor.tsx`) get a
      one-time `cm-arrived` line decoration — background fades from `--success-soft` to transparent over
      `--duration-base × 3`, then the decoration is removed (StateEffect + setTimeout dispatch). No animation for
      typed text or AI streaming (the shimmer already covers AI).
- [ ] Commit: `style: code surfaces, clean snippets, append arrival cue`

---

## Phase P7 — Invited marginalia (migration v21)

Read artifact §7.5 first. Depends on P4 (spans/anchoring machinery, hover/tooltip patterns).

### Task 7.1: Schema + Read back pipeline

**Migration v21 (exact DDL):**
```sql
CREATE TABLE margin_notes (
  note_id     TEXT PRIMARY KEY,
  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
  anchor_start INTEGER NOT NULL,         -- UTF-16, mapped like spans
  anchor_end   INTEGER NOT NULL,
  anchor_hash  TEXT NOT NULL,            -- FNV-1a of anchored text
  kind        TEXT NOT NULL,             -- 'question' | 'tension' | 'connection'
  body        TEXT NOT NULL,
  body_hash   TEXT NOT NULL,             -- dedupe/suppression key
  request_id  TEXT,
  status      TEXT NOT NULL DEFAULT 'open',  -- open|dismissed|promoted|unanchored
  created_at  DOUBLE NOT NULL
);
CREATE INDEX idx_margin_stream ON margin_notes(stream_id);
CREATE TABLE margin_suppressions ( stream_id TEXT NOT NULL, body_hash TEXT NOT NULL,
  PRIMARY KEY (stream_id, body_hash) );
```

**Read back (Swift):** new web→swift `readBack { streamId, scopeStart, scopeEnd }` (UTF-16 offsets of the scope;
web computes viewport/section/document ranges). `AIMessageHandler`:
1. Prompt (add `Prompts.readBack`):
```
You are reading a draft back to its author. Identify at most 5 notes about the passage below.
Each note is one of: "question" (a gap or unexamined assumption), "tension" (a contradiction
with the text itself or the provided source passages), "connection" (a directly relevant
passage from the provided sources).
Return ONLY a JSON array: [{"kind":"question|tension|connection","anchor":"<exact verbatim
quote of 5-15 consecutive words from the passage>","body":"<the note, 1-3 sentences, plain
prose, no lists>"}]
The anchor MUST be copied character-for-character from the passage. Do not comment on style
or formatting. Do not praise. If nothing is worth noting, return [].
```
   Context = the scoped text + retrieval over the stream's sources (existing `assembleSourceContext`, scope auto).
2. Parse strictly (JSON decode; on failure return empty — never retry in a loop). For each item: locate `anchor`
   in the scoped text using whitespace-collapsed, curly-quote-normalized matching (port the normalization approach
   from `PDFReaderPaneController`'s `NormalizedTextMap` into a shared
   `Sources/Ticker/Models/NormalizedTextSearch.swift` — do NOT reach into the PDF controller); unverifiable →
   drop silently, `DebugLog` the count.
3. Dedupe: drop items whose `body_hash` is in `margin_suppressions` or equals an existing non-dismissed note.
4. Insert rows (cap 5), send new swift→web `marginNotesChanged { streamId, notes: [...] }`.
`streamLoaded` payload gains `marginNotes: [...]` (open + unanchored only).

**Steps:**
- [ ] Migration + CRUD + normalized-search unit tests (straight/curly quotes, collapsed whitespace, no match →
      nil); parse-failure test (garbage model output → empty, no crash).
- [ ] Contract entries: `readBack`, `marginNotesChanged`, extended `streamLoaded`. Checker green.
- [ ] Commit: `feat(marginalia): schema + invited read-back pipeline (v21)`

### Task 7.2: Margin UI — render, promote, dismiss, unanchor

**Files:** `Web/src/extensions/MarginNotes.ts` (new), `StreamEditor.tsx`, `index.css`.

- Header toggle (SF-style note icon) next to the x-ray toggle; toggling on reveals notes and the “Read back” action
  button (with scope select: Viewport / Section / Document — section = the heading-bounded region containing the
  cursor; compute from the syntax tree).
- Wide layout (window ≥ 1100px CSS): absolutely-positioned note cards in the right margin, top-aligned to the
  anchor's first line (`view.coordsAtPos`), 200px wide, `--type-ui-small`, kind label chip + body + actions
  `↑ promote · × dismiss`. Vertical collision: stack downward with 8px gaps.
- Narrow layout: CM gutter dots (kind-colored, `--radius-small`); click → the note as a popover (selection-menu
  surface pattern).
- Anchor mapping: notes' anchors map through edits exactly like spans (extend `ProvenanceField` or a parallel
  field reusing its mapping helpers). On load and after edits, `anchor_hash` mismatch → status `unanchored`:
  render grayed at the top of the margin with “passage changed” and only `× dismiss`.
- Promote: inserts `\n\n` + note body at the anchor's paragraph end via a normal transaction CARRYING an ai span
  (`origin:'ai'`, requestId from the note) — fused register per D2; note status → `promoted`, disappears from margin.
- Dismiss: status → `dismissed` + insert into `margin_suppressions`. Persist note status changes via new web→swift
  `updateMarginNote { noteId, status }`.
- Note bodies are NOT editable (D10) — no input surfaces anywhere.

**Steps:**
- [ ] Contract: `updateMarginNote`. Vitests: collision stacking (pure layout fn), anchor-mismatch → unanchored,
      promote produces correct insert + span.
- [ ] Verify live: Read back on the Forth stream (scratch copy) → notes appear anchored; edit the anchored sentence
      heavily → note grays to “passage changed”; promote one → text lands with a span (x-ray confirms); dismiss
      one → re-running Read back never re-offers it.
- [ ] Commit: `feat(marginalia): margin rendering, promote/dismiss, honest unanchoring`

### Task 7.3: Follow-through — Challenge moves to the margin; the badge becomes real

- [ ] Challenge (Task 3.2) now creates a margin note (`kind:'tension'`, request-linked) instead of an inline
      blockquote, whenever the margin system is available (always, after 7.2). Delete the inline-quote wrapper and
      its `ponytail:` ceiling comment.
- [ ] `StreamCodec.encodeSummaries` gains `openQuestionCount` (COUNT of `margin_notes` where status='open' AND
      kind='question'); stream list card shows the `N open questions` badge when > 0 (accent-soft chip, the mock in
      the artifact §4.1).
- [ ] Verify live; commit: `feat(marginalia): Challenge lives in the margin; open-questions badge`

---

## Phase P8 — Shell polish

### Task 8.1: The app remembers itself
- [ ] `AppDelegate.setupMainWindow`: `window.setFrameAutosaveName("TickerMainWindow")`; the right-⅜ computation
      runs ONLY when no saved frame exists (first launch).
- [ ] Reopen last stream: persist last open stream id in `UserDefaults` on stream open; on launch, after the web
      app signals ready, send the existing `loadStream` flow for it (guard: stream still exists). Skip when launch
      was triggered by a file-open/deep-link event.
- [ ] `developerExtrasEnabled` (`WebViewManager.swift:~28`): wrap in `#if DEBUG`.
- [ ] Verify: quit/relaunch → same frame, same stream, no Inspect Element in a Release build (`run-prod`).
- [ ] Commit: `fix(shell): frame + last-stream restoration; dev tools debug-only`

### Task 8.2: URL scheme (capture ubiquity, first channel)
- [ ] `Info.plist`: `CFBundleURLTypes` with scheme `ticker`. `AppDelegate` handles
      `ticker://append?stream=<uuid|title>&text=<percent-encoded>` → `appendToStreamDocument` (+ capture-origin
      span) and `ticker://open?stream=<uuid>` → open stream. Unknown/malformed → `DebugLog` + no-op (no dialogs).
      Text cap 10k chars (same as clipboard rung).
- [ ] Tests: URL parse unit tests (missing params, bad uuid, over-cap).
- [ ] Verify: `open "ticker://append?stream=…&text=hello%20world"` from a terminal lands in the stream with a
      capture span.
- [ ] Commit: `feat(shell): ticker:// URL scheme for append/open`
- [ ] OUT OF SCOPE (explicitly deferred, do not start): Share extension, Services menu, Shortcuts/App Intents,
      rebindable hotkeys, onboarding rework, “continue in stream”.

---

## Cross-cutting verification (run at every phase boundary)

1. `./tickerctl.sh build-dev && ./tickerctl.sh swift-test`
2. `cd Web && npm run typecheck && npm test && npm run build`
3. `node tools/contracts/check_bridge_contract.mjs`
4. Editor baseline: open stream → edit → copy/paste → each AI verb + one-⌘Z undo → save/reload → image
   insert/reload → quick panel ↵/⌘↵/⌥↵/Esc → PDF open/highlight/link round-trip.
5. Provenance baseline (P4+): develop → x-ray on → tint/hover/dissolve/undo → x-ray off → pristine; capture →
   span present; save/reload → spans survive; heavy edit → slivers gone after save.
6. Data safety: backup DB before any live drive; clean every test fragment; `pgrep -x TickerNext` for strays.

## What NOT to do (failure modes for the implementing model)

- Do NOT store provenance in the markdown (markers, comments, zero-width chars). Sidecar only.
- Do NOT feed `ai_exchanges` or document history into any prompt (D1). `priorCells: []` except the quick panel's
  own live ephemeral turns.
- Do NOT add chat UI: no message bubbles, no avatars, no per-block attribution headers in the document.
- Do NOT auto-generate margin notes without an explicit Read back invocation.
- Do NOT infer provenance for existing text (D9).
- Do NOT count offsets in Swift with `count`/`String.Index` character arithmetic — `utf16` everywhere (D11).
- Do NOT edit migrations v1–v17; new schema = new migration.
- Do NOT let any AI path skip the one-undo-step invariant.
- Do NOT ship a permanent visual marker on AI text (D4) — tints exist only under the x-ray toggle.
- When a verification step needs the live app: copy the DB aside first, and prefer user-driven verification for
  AI round-trips when the user is at the machine.
