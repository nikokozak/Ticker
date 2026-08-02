# Conversations — Block-Anchored AI in the Stream

Status: PLANNED (2026-08-01). Governed Codex execution; Claude orchestrates, Codex 5.6 Sol implements, no sub-agents.
Supersedes the Thread/Sidenote drawer direction. Canonical product rationale: the 4-round design review
(drawer → sidenotes → block-anchored conversations); this doc is the implementation contract.

---

## 0. Verdict on the existing branch — explicit

**Do NOT kill `codex/stream-threads-prototype`. Build on it.** Reasons, measured:

- Its merge-base with `main` IS main's tip (`cda5fa6`, the richtext release). Zero rebase cost.
- Of its ~9,047 inserted lines, the majority is **substrate the new design needs unchanged or lightly adapted**:
  - `v28_stream_threads` + `v29_sidenote_documents` migrations (thread rows, `ai_exchanges.thread_id`,
    `thread_disposition`, `stream_thread_anchors` with `stream_quote`/`pdf_quote` kinds) — the conversation
    data model is ~90% already here.
  - Bridge contract + handlers: `createStreamThread`, `loadStreamThread`, `saveStreamThread`,
    `listStreamThreads`, `deleteStreamThread`, `addStreamThreadAnchor`, `removeStreamThreadAnchor`,
    `setThreadExchangeDisposition`, `threadAIContext`, `pdfThreadRequested`.
  - `AIOrchestrator` thread-context assembly (+269) and the `ThreadAISentFacts` receipt system
    (`Web/src/threads/context.ts`) — carries over with a version bump.
  - `Web/src/threads/session.ts` revision-checked autosave — reusable pattern.
  - ~1,165 lines of Swift persistence tests + web tests for the above.
- What dies is concentrated and separable: `ThreadDrawer.tsx` (+ test, ~1,430 lines), the placement mode
  inside `RichStreamEditor.tsx` (`pendingSidenotePlacementRef`, `ticker-thread://` chips, `placement`
  anchor kind), the sidenote draft document (`doc_json` usage), and a large slab of drawer CSS in
  `Web/src/styles/index.css`. Deleting is cheaper than re-porting the substrate commit-by-commit.

**Working tree:** continue in `/Users/niko/Developer/Ticker/Ticker-Next-stream-threads`.
New branches stack from `db9bcf6`: `codex/conv-c0`, `codex/conv-c1`, … one branch + one PR per phase.

**`codex/editor-stability-fixes` (main checkout, 1 commit `70c5f3a`):** touches only legacy CodeMirror
extensions (`MarkdownConceal`, `LinkInteraction`, `MarkdownImageWidget`, `PDFHighlightLink`). Main runs
`USE_RICH_TEXT_EDITOR = true`, so that code path is dormant. Leave the branch; do not stack on it; merge
or drop it independently of this effort.

---

## 1. The product object

A **conversation** is an AI-and-human exchange attached to one block (or contiguous span) of the Stream.
It renders inline, indented beneath its block — not in a drawer, panel, or modal. Collapsed, it is a
small glyph in the right gutter. Nothing in a conversation enters the Stream document unless the user
promotes it. The Stream document (markdown) remains the single source of truth; conversations are
sidecar data.

### Locked decisions (do not re-litigate in implementation)

| # | Decision |
|---|---|
| D1 | Conversations are **sidecar rows rendered via ProseMirror block widget decorations + React portals**. They never appear in the markdown, exports, clipboard, or the document AI context of *other* requests. |
| D2 | Anchor = **UTF-16 span sidecar** riding the same position-mapping approach as provenance spans (`Web/src/richtext/provenance.ts`, v24 machinery). No block IDs in the schema, no markdown pollution. |
| D3 | **Exclusive expansion.** Expanding a conversation collapses any other. Collapsed = right-gutter glyph. Open affordance = left-gutter line on the hovered/current block. No typewriter/focus mode required (explicitly out of scope). |
| D4 | **Context = full by default.** Every request sends: anchor block (primary), whole Stream doc, retrieval per the existing Sources scope chip, bounded prior turns of THIS conversation. Plus **pinned context**: user-added PDF/Stream selections stored as `stream_thread_anchors` rows, shown as removable chips. Receipts record all of it. |
| D5 | **Promotion** = insert the chosen response block(s) into the document immediately after the anchor block. One undo step. Promoted text gets a normal AI provenance span (existing machinery) — no `[Thread]` chip, no backlink chip. |
| D6 | **PDF flow = "Quote & discuss."** Starting a conversation from a PDF selection inserts a cited quote block (blockquote + `ticker-pdf://` link) into the Stream at the current cursor (end of doc if none) via the normal explicit-action path, creates the highlight, and anchors the conversation to that quote block. Every conversation is therefore block-anchored; highlight-click navigates to the quote block and opens its conversation. |
| D7 | **Slash commands** on an empty paragraph: `/` opens a two-item menu v1 — `chat` (ephemeral conversation anchored to the previous block) and `research` (conversation with the research prompt profile; proxy already always offers `web_search`). Selection-menu AI verbs are untouched. |
| D8 | **`update_block` tool.** The model may call one tool that replaces the text of the conversation's anchor span only. Applied as one undo step with a flash; the exchange records before/after text. Requires Ticker-Proxy tool passthrough (own phase; blocked until proxy side lands). |
| D9 | `/chat` conversations persist **nothing** unless the user promotes a response or explicitly keeps the conversation on collapse. |
| D10 | Table names stay (`stream_threads`, `stream_thread_anchors`, `ai_exchanges`). New code says "conversation"; no mass rename migration. |
| D11 | Sidenote draft columns (`doc_json`, `doc_format_version`, `working_text`, `title`) stop being written; columns stay (frozen). The `evidence` schema node is **deleted** (D6 uses plain blockquote + link). |
| D12 | Design language: iA-Writer-calm per §6. Typography and whitespace carry hierarchy; chrome recedes; pills/cards/shadows go. |

### Anchor lifecycle rules (verbatim; encode in tests)

1. A conversation anchors to a contiguous UTF-16 range in the canonical document, initially the full
   text of one block. The range maps through every transaction (same mapping discipline as provenance
   spans). The conversation renders after the **last block intersecting the range**.
2. Block split inside the range: the range now spans both halves; render rule (1) keeps the
   conversation after the second half. No user-visible event.
3. Block merge: range persists into the merged block. No user-visible event.
4. Range deleted to empty: the conversation becomes **detached** — glyph leaves the gutter; the
   conversation remains reachable from the Conversations list (header overflow) labeled "detached".
   Nothing is auto-deleted, ever.
5. Store `anchor_text` (first 200 chars) at creation; on open, if the current range text no longer
   contains/matches it, show a one-line muted note inside the conversation header: "The passage has
   changed since this conversation started." No modal, no amber banner.
6. Anchors persist on document save in the same transaction as the save (v30 columns), exactly like
   provenance spans travel today. External appends (`streamDocumentAppended`) map ranges by offset.

### UI states (wide window; narrow just narrows — no takeover, no drawer)

Collapsed (default; a block with a conversation):

```
   That makes voltage tolerance the rejection gate. Record
   measured current beside each candidate.                ◆   ← right gutter, 55% accent
```

Hover / cursor inside a block (any block):

```
 ▎ Candidate regulator: TPS62177. Verify peak current,        ← left gutter line, full block
   package availability, and thermal limits.                    height; click = open/create
```

Expanded:

```
   Candidate regulator: TPS62177. Verify peak current,
   package availability, and thermal limits.
   ▏
   ▏  You   Does this part survive our worst-case draw?
   ▏
   ▏  AI    The datasheet caps supply current at 500 mA
   ▏        (p. 12); your note requires 600 mA continuous,
   ▏        so this fails the rejection gate.            ↑    ← hover: "Add to Stream"
   ▏
   ▏  [⎘ nRF54L15 p.12 ×] [⎘ ¶ quote ×]                       ← pinned context chips (if any)
   ▏  ┌──────────────────────────────────────────────┐
   ▏  │ Ask — sees this block, the Stream, and sources│  ⌘↵
   ▏  └──────────────────────────────────────────────┘
```

Spec: container indented 28px; 2px rail in `--accent` at 25%; **no background card, no border**;
conversation type 15/24 vs document 17/28; "You" turns muted, AI turns full text color; controls appear
on hover only. Expand/collapse 150ms ease-out. Clicking the rail (or the left-gutter line, or Esc with
composer empty) collapses. Streaming renders progressively into the last AI turn.

---

## 2. Data model (migration v30 — one migration, append-only)

```sql
-- v30_conversation_anchors
ALTER TABLE stream_threads ADD COLUMN anchor_start INTEGER;   -- UTF-16 offset in canonical doc
ALTER TABLE stream_threads ADD COLUMN anchor_end   INTEGER;
ALTER TABLE stream_threads ADD COLUMN detached     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE stream_threads ADD COLUMN ephemeral    INTEGER NOT NULL DEFAULT 0;  -- /chat, D9
-- anchor_text reuses existing anchor_text column (v28).
```

Existing rows: prototype-era threads get `detached = 1` (their drawer anchors don't translate);
they stay readable in the Conversations list. Real-DB safety: back up `ticker.db` before first launch
of any build from these branches (v28–v30 will run on it).

Kept as-is: `ai_exchanges` (+ `thread_id`, `thread_disposition`), `stream_thread_anchors`
(`stream_quote` / `pdf_quote` = pinned context; `placement` kind becomes dead — leave the CHECK, stop
writing), receipts in `sent_context`.

---

## 3. Bridge contract deltas (update `docs/contracts/bridge.v2.json` + `Web/src/types/bridge.ts` in the same commit as each change; contract checker gates CI)

- KEEP: `saveStreamThread` (slimmed), `threadAIContext`, `pdfThreadRequested` (repurposed for
  Quote & discuss).
- C0 OUTCOME (2026-08-01): `createStreamThread`, `loadStreamThread`, `listStreamThreads`,
  `deleteStreamThread`, `addStreamThreadAnchor`, `removeStreamThreadAnchor`,
  `setThreadExchangeDisposition` had zero web callers after drawer deletion and were removed from the
  contract + `bridge.ts` + handler registration per the zero-caller rule. Their PersistenceService
  methods and Swift tests survive. **C3/C4 re-add the entries they need** (C3: create/load/list/delete
  + exchange disposition; C4: anchor add/remove). C3 also restores anchors/exchanges on the
  `saveStreamThread` conflict-path response (currently title/revision only) and, if needed, the Swift
  `placement` anchor-kind decode case that C0 dropped (dead rows; v30 marks prototype threads
  detached regardless).
- CHANGE: `saveStreamThread` slims to anchor/ephemeral/detached updates (no draft doc payload).
- ADD: `saveConversationAnchors` (batch, rides document save like provenance spans if not already in
  that payload), `promoteConversationTurn` is **not** a bridge message — promotion is a ProseMirror
  transaction + normal save path.
- REMOVE: any drawer-only messages discovered during C0 that have no caller after deletion (Codex lists
  them in the PR body; contract entries removed in the same commit).

---

## 4. What is deleted (C0 inventory)

- `Web/src/components/ThreadDrawer.tsx`, `ThreadDrawer.test.tsx`.
- In `RichStreamEditor.tsx`: `pendingSidenotePlacementRef`, `startPDFSelectionThread` placement path,
  `retryThreadInsertionSave`, `SidenoteMarkerChooser`, `THREAD_URL_PREFIX` / `ticker-thread://`
  handling, placement span creation (`kind: 'placement'`), `defaultThreadTitle`, sidenote marker
  add/remove plumbing.
- `evidence` node in `Web/src/richtext/schema.ts` + its serializer/parser + CSS.
- Drawer/sidenote CSS blocks in `Web/src/styles/index.css`.
- `ThreadDraftSession` usages tied to draft docs (keep the class if C4 reuses it for anchor saves;
  otherwise delete).
- Swift: sidenote draft save paths in `PersistenceService` stay (frozen columns) but handler code for
  draft-doc saving is trimmed to the slimmed `saveStreamThread`.

---

## 5. Context model (C4, resolves review point #5)

Default per request: `[anchor block text] + [whole Stream markdown] + [retrieval via existing
assembleSourceContext honoring the Sources scope chip] + [bounded prior turns of this conversation]`.
Anchor is marked "primary" in the prompt frame. Pinned context rows are injected verbatim (quotes) or
as retrieval bias (whole-source pins later; v1 = selections only).

Pinning UI: a quiet `+ context` text button in the composer row →  menu built from live state:
"PDF selection" (PDF pane open + selection non-empty), "Stream selection" (editor selection non-empty
and outside this conversation). Each pin = one `stream_thread_anchors` row; chips above the composer;
`×` removes (row delete). Receipts: `ThreadAISentFacts` version 2 adds `pinned: [...]` and the anchor
range; `Web/src/threads/context.ts` parser extended with tests.

---

## 6. Design language revamp (C1) — iA Writer calm, concrete values

Current state to fix: bordered pill buttons everywhere, card-styled surfaces, busy header, generic
list rows. Target: typography carries hierarchy; chrome is text; color is rare.

- **Type:** document body 17/28 (system stack), measure `max-width: 64ch`, top padding 96px. H1 24/32
  semibold, H2 19/28 semibold, H3 17/28 semibold. UI chrome 13/16; metadata 12/16; conversation 15/24.
  No ALL-CAPS labels anywhere.
- **Chrome:** editor + list headers become transparent; hairline bottom border appears only after
  scroll > 0. Header controls are plain text at `--text-muted`, full `--text` on hover; no borders,
  no fills, no pills. "Saved" renders only as transient "Saving…" (fades 800ms after settle).
  Counts hidden at zero.
- **Stream list:** typographic rows — title 17 medium, one-line preview 14 `--text-muted`, meta 12
  `--text-faint` (relative time only; drop word/char counts from rows). Hairline separators
  (`--border-subtle`); hover = `--surface-hover` tint; no cards, no radius, no shadow.
- **Buttons:** collapse to two tiers: Primary (accent text or accent fill for the single main action
  per surface, e.g. New Stream) and Quiet (plain text, hover tint). Delete the bordered-pill style
  globally.
- **Color:** `--accent` sienna stays the only accent; provenance tints remain x-ray-only (already
  true); danger/warning unchanged. Shadows only on floating popovers (`--control-shadow`); none on
  inline surfaces. Radii: 6px controls, 4px chips; no 10px+ cards in the editor.
- **Dark:** same rules through the existing dark token block; verify conversation rail/tint in both.
- Deliverable includes a before/after screenshot pair per surface (list, editor, selection menu,
  sources modal) in the PR body.

---

## 7. Phases — one Codex session, one branch, one PR each; every round ends with all gates green

Gates (every round): `./tickerctl.sh build-dev` · `./tickerctl.sh swift-test` ·
`cd Web && npm run typecheck && npm test && npm run build` ·
`node tools/contracts/check_bridge_contract.mjs`. Live verification is user-driven
(no synthetic GUI input; Niko smoke-tests per the editor-slice baseline + the new checks below).

### C0 — Surgery (branch `codex/conv-c0` from `db9bcf6`)
Delete §4 inventory; slim `saveStreamThread`; keep substrate compiling and contract-clean with the UI
gone (temporary: no way to open a conversation — acceptable for one PR).
**Accept:** all gates green; `git grep -i "sidenote\|placement\|ticker-thread" Web Sources` returns
only frozen-column comments; contract checker passes with pruned entries; markdown round-trip tests
still pass with `evidence` node removed.

### C1 — Design language (`codex/conv-c1`)
Implement §6 exactly. Token edits + component CSS + list/header/editor chrome. No behavior changes.
**Accept:** gates; zero bordered-pill classes remain; screenshots in PR; dark parity screenshots.

### C2 — Anchors (`codex/conv-c2`)
v30 migration; `ConversationAnchorField` in the rich editor modeled on the provenance span field
(mapping, save-in-same-transaction, append-offset handling); lifecycle rules 1–6 as unit tests
(split/merge/delete/detach/drift); right-gutter glyph + left-gutter line rendering from the field
(decorations only — no interactivity yet beyond click stubs).
**Accept:** gates; Swift migration test on fixture DB incl. prototype rows → `detached=1`; web tests
prove the five lifecycle rules; per-frame work bounded by visible ranges (editor perf invariant 6).

### C3 — Inline conversation surface (`codex/conv-c3`)
Block widget decoration hosting a React portal (pattern reference: `ExchangeOverlay` positioning);
expand/collapse per D3 with exclusive rule; composer (⌘↵ sends) wired to the existing thread AI
orchestrator path; streaming into the last turn; turns rendered from `ai_exchanges`; §1 UI spec values.
**Accept:** gates; expanded conversation is fully keyboard-reachable (Tab into composer, Esc
collapses); document editing above/below an expanded conversation never moves the caret into it;
no layout shift of document text when collapsing (gutter reserves no width).

### C4 — Context + receipts (`codex/conv-c4`)
§5: default full context; pinned-context chips + `stream_thread_anchors` wiring; receipts v2 +
parser tests; "What AI saw" disclosure inside each AI turn (collapsed by default).
**Accept:** gates; receipt round-trip test (send → persist → parse → render); pin/unpin persists
across app relaunch.

### C5 — Promotion + PDF Quote & discuss (`codex/conv-c5`)
Hover `↑ Add to Stream` on AI turns → insert after anchor block, one undo, provenance span, flash;
`pdfThreadRequested` repurposed: PDF selection action inserts cited quote block + highlight + anchored
conversation (D6); highlight click → scroll to quote block + expand its conversation.
**Accept:** gates; single ⌘Z reverts a promotion exactly; promoted text carries an AI provenance span
visible under x-ray; PDF round-trip (select → discuss → promoted quote → click highlight → conversation
expands) passes user smoke.

### C6 — Slash commands + ephemeral chat (`codex/conv-c6`)
`/` on empty paragraph → menu (`chat`, `research`); D7 + D9 semantics; ephemeral conversations render
identically but persist only on promote/keep ("Keep" appears in the conversation header for ephemeral
ones); the empty paragraph hosting `/` is removed when the command fires.
**Accept:** gates; `/chat` → collapse without keep → zero rows in DB; `/research` request carries the
research profile flag in its receipt.

### C7 — `update_block` tool (`codex/conv-c7`; BLOCKED on Ticker-Proxy passthrough)
Proxy task (separate repo, own session): pass a `tools` array through the Responses API and stream
tool-call events back. Client: offer `update_block` only for stream-anchored, non-detached
conversations; apply = replace anchor span content, one undo, flash; exchange row records
before/after; conversation shows "AI edited this block — Undo available".
**Accept:** gates both repos; tool cannot touch anything outside the anchor span (unit test with
adversarial offsets); undo restores byte-identical markdown.

### C8+ — Horizon (approved 2026-08-01; start only after C7; in this order; each independently shippable and killable)

All of these ride the conversation surface (C3) and the trust contract in
`docs/CONNECTIONS_BACKGROUND_THINKING_DESIGN.md`: evidence-bound, verbatim passages only, silence
over weak output, no model-originated citations, no ambient commentary.

- **C8a `/connect` — manual Connections.** Slash command; retrieval-only, generation-free
  juxtaposition per the Connections doc's "smallest validation path" steps 1–4. Renders as a
  conversation-shaped card: stream excerpt + verbatim source passage + page link + actions
  **Open passage** / **Quote here** (= D6) / **Dismiss**.
  *Accept:* no candidate above threshold → one quiet "nothing found" line; every card element
  resolves (passage flash-verifies in the PDF); dismissals persist and suppress re-surfacing.
- **C8b Source hub + library.** Per-source page: metadata, outline, all highlights, promoted
  quotes, conversations, and cross-stream backlinks ("cited in N streams" — `source_id` joins on
  `pdf_highlights` / `stream_thread_anchors` / chunks). A library view (all sources, reading
  progress, highlight counts) is its front door. Do this before any new source *types*.
  *Accept:* every listed item navigates to its stream block or PDF location.
- **C8c `/check` — reconciliation pass.** On-demand, stream-level: claim-bearing blocks checked
  against this stream's sources via existing retrieval + verified-quote machinery; findings render
  as a conversation of juxtapositions (your block, the verbatim passage that contradicts or
  undercuts it, page link). No free-form critique; no finding without a verified passage.
  *Accept:* zero findings → one quiet line; each finding's passage flash-verifies in the PDF.
- **C8d Background Connections.** The per-stream "Keep thinking about this stream" opt-in with the
  Connections doc's restraint rules (idle-triggered, ≤1 per run, ≤3 unresolved, no notifications,
  no empty states). Start only after C8a proves users open and quote the manual results.
- **C8e `/interview`.** Conversation profile where the AI asks short gap-filling questions about
  the anchor block/stream; the user's typed answers are promoted like any turn and carry human
  provenance. Prompt profile only — no new machinery.
- **C8f Export with receipts.** Export transforms `ticker-pdf://` citation links into real
  footnotes (source short title + page). Completes backbone → deliverable.

Still deferred, no date: conversations FTS search, detached-conversations archive viewer beyond the
plain list, whole-source pins, multi-block anchor creation from multi-block selections, nested
conversations, collaboration, new source types (web/email) before C8b exists. Refused outright, not
deferred: canvas/graph/board views, persistent research sidebar, autonomous multi-step agents
acting on the Stream.

---

## 8. Codex orchestration protocol (governor copies this into practice)

- Model: **`gpt-5.6-sol` at max reasoning** for C2/C3/C7 (design-heavy); Sol medium is acceptable for
  C0/C1/C4/C5/C6 if the governor judges the brief fully specified (comparison data says medium ≈ high
  on well-specified briefs). **Never enable multi_agent_v2 / sub-agents.**
- **One warm session across phases**, not one per phase: resume the same session id for every round
  and every subsequent phase (`codex exec -s workspace-write resume <SESSION_ID> "<brief>"`, `-s`
  before `resume`) so accumulated repo/plan context is never re-bought. Launch from the **worktree
  root** (`Ticker-Next-stream-threads`); `< /dev/null` when backgrounded with no stdin prompt.
  Compact proactively between phases (`codex exec resume <id> "/compact"`); start a FRESH session
  only after the session has compacted more than once (context degraded past usefulness), re-primed
  by pointing it at this doc, and record the new id in memory.
- Sandbox git is flaky: tell Codex to commit on the current branch; governor pre-creates branches and
  commits for Codex when `.git` writes are denied.
- Every prompt embeds: the ponytail ladder (does it need to exist → stdlib → platform → existing dep →
  one line → minimal code; `// ponytail:` comments name ceilings), the invariant list (CLAUDE.md §
  Invariants), the phase's Accept list verbatim, and **an explicit "do not delete existing features
  not named in this brief" line** (lesson: exact-layout specs tempt Codex to drop unlisted features).
- Plan-doc constants must be computed, not asserted (FNV lesson): where this doc states offsets or
  values Codex must verify at runtime, it should trust the code over the doc and report discrepancies.
- Governor reviews every round's diff, runs gates independently, and updates the session/status table
  below. User runs live smokes; DB backup before any launch against the real profile.

| Phase | Branch | PR | Status |
|---|---|---|---|
| C0 | codex/conv-c0 | #68 | DONE 2026-08-01 |
| C1 | codex/conv-c1 | #69 | DONE 2026-08-01 |
| C2 | codex/conv-c2 | #70 | DONE 2026-08-01 |
| C3 | codex/conv-c3 | #71 | DONE 2026-08-01 (swift-test correction noted on PR) |
| C4 | codex/conv-c4 | #72 | DONE 2026-08-01 (v31 profile migration added in C6) |
| C5 | codex/conv-c5 | #73 | DONE 2026-08-01 |
| C6 | codex/conv-c6 | #74 | DONE 2026-08-01 |
| C7 | codex/conv-c7 + Ticker-Proxy `codex/tool-passthrough` (`7c636aa`) | #75 | DONE 2026-08-01 — proxy NOT deployed; deploy before the tool can fire live |

All phases governed by one warm Codex session (`019fbe73-…93f8`) + one proxy session; every phase
independently gated (exit codes) and Opus-reviewed with fix rounds. Merge order: #68→#75, one at a
time (retarget-race lesson). User-reserved: PR merges, Fly deploy of the proxy branch, live smokes
(editor-slice baseline + conversation flows + Quote & discuss round-trip + /chat ephemerality +
update_block on a real stream), light/dark visual pass on C1.

---

## 9. Non-goals and kill criteria

Non-goals: nested conversations; conversation branching/compare; statuses; cross-stream conversations;
typewriter focus mode; sources paradigm rework beyond D6; export of conversations.

Kill criteria (measure during dogfood): if conversations are opened but promotion stays near zero AND
external-chat pasting continues → the inline surface is the wrong shape; keep anchors + quote-capture,
rethink the surface. If exclusive expansion is repeatedly fought (users reopening two constantly) →
revisit D3 before inventing multi-expand. If `/chat` ephemerality confuses (lost work reports) → make
`/chat` persist-by-default and cut D9.
