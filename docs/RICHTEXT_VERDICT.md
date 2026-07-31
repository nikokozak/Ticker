# The ProseMirror editor: what happened, and what to do

Written 2026-07-29, after the editor was enabled for one real run and turned back
off. Branch `codex/richtext-spike`. Contains Claude's analysis and Codex's
independent verdict; where they disagreed, both readings are kept.

> **Status — 2026-07-31:** This is the historical failure analysis, not the
> current editor state. The failures below were fixed forward on this branch.
> A copy-only conversion rehearsal preserved the source database byte-for-byte,
> retained every stream, source, document, and append-inbox row, and produced 25
> valid canonical documents. The converter now refuses already-canonical input
> or unresolved inbox rows rather than risk replaying projected content. In the
> Release WKWebView, a 1,999-line/14k-word
> stream opened in 439 ms, scrolled end-to-end without a stall, saved selected
> formatting, survived three reopen cycles (422–435 ms), and passed immediate
> undo/redo with revision-checked saves. The branch remains unmerged pending
> explicit user acceptance.

## What the user hit

Pressing Enter snapped the cursor back to the previous line. Multiple blank lines
were impossible. Selection highlighted text it should not have, and formatting
landed on other passages. Provenance clicks opened the exchange only sometimes.
Backing out of a stream and re-entering it froze the app.

Images from the web and one-step AI undo worked.

640 web tests passed throughout.

## Root causes

**Enter, and blank lines — confirmed, reproduced in a six-line unit test.**
`getMarkdown()` mutates: it calls `normalizeNow()`, which dispatches normalisation
into the live document. The session's dirty check calls `getMarkdown()`, so the
350ms autosave makes normalisation effectively live. `dropEmptyParagraphs` then
deletes the paragraph Enter just created, and ProseMirror maps the cursor back.

`closure.test.ts` explicitly blesses that deletion. The tests agreed with the bug.

**Selection and formatting — confirmed defect, extent unproven.**
`prosemirror-view/style/prosemirror.css` is not imported anywhere. The hand-written
replacement omits `white-space: break-spaces` and the ligature-disabling rules,
which exist precisely to keep caret and DOM geometry reliable. The formatting
commands themselves are stock `toggleMark`, so the fault is in DOM-selection →
document-position translation, not in the commands. Whether the missing CSS fully
explains sentence-scale errors needs `window.getSelection()` logged beside
`view.state.selection` in WebKit.

**Sporadic exchange — confirmed brittle.**
The decoration already carries a stable `data-span-id`, and the component ignores
it, converting the DOM node back to a position with `posAtDOM` and re-searching
spans with an inclusive boundary test. Split or overlapping decorations make that
ambiguous. It also requests exchanges for any origin with a requestId, so capture
and source spans ask for something that does not exist and fail silently.

**Freeze — NOT diagnosed. Claude's hypothesis was wrong.**
Claude guessed a React effect loop from unstable array identities in the
`documentLoaded` dependencies. Codex refuted it: `App` holds the loaded stream in
state, and the effect returns early unless the revision is newer, so an identity
change re-evaluates a guard rather than re-entering. The real candidates are
main-thread stall and lifecycle overlap: ProseMirror renders the whole document
with no viewport virtualisation, mount synchronously parses, normalises,
serialises, hashes every span and builds all decorations, React Strict Mode
replays mount effects in dev, and teardown holds the old `EditorView` while
asynchronous session destruction finishes. Needs one WebKit profile captured
during reproduction.

## Is ProseMirror wrong for this product?

Both analyses say no, for the same reason. The product rule is that markup must
never be reachable by the user. A document model gives that directly — formatting
is nodes and marks — where CodeMirror gives it only by concealing source the
cursor can still walk into, which is the problem this work existed to escape.

The mismatch is not editor-vs-editor. It is that **CommonMark was kept as the
canonical store**, and CommonMark cannot encode every state the editor permits.
The implementation resolved that by deleting the user's structure at save time.
That is a codec-policy failure.

Measured: `normalize.ts` (428 lines), `closure.test.ts` (545), and much of
`markdown.ts` (452) exist only to keep the live document inside markdown's
expressible subset and prove the round trip. That is the tax being paid.

Two ways out, and this is the real decision:

1. Keep markdown canonical, and give every editor-reachable state a stable
   markdown encoding — including blank paragraphs — instead of normalising it
   away. Smaller change, keeps the invariant in `CLAUDE.md`, keeps the tax.
2. Make the document model canonical and markdown an export format. `normalize.ts`
   and the closure gate stop existing. Costs a migration and rework of the append
   primitive, search, and the AI paths, all of which assume a markdown string in
   `stream_documents`.

A separate, unmeasured risk either way: ProseMirror does not virtualise the
viewport. If streams routinely reach thousands of lines this must be measured in
the real WKWebView before recommitting.

## Options

| | Cost | Keeps |
|---|---|---|
| Fix forward | ~4–6 focused days (Codex's estimate), freeze is the risk | everything |
| Rebuild editor layer, keep codec + session | most of the 4–6 days; scoped to hundreds of lines, not the 3,843 under `richtext/` | schema, markdown codec, session, pendingAppends, provenance mapping, AI/image operations, bridge wiring |
| Revert to CodeMirror | not free: provenance coordinates were migrated from markdown offsets to PM positions (v24/v25), the CodeMirror conflict path still replaces a dirty editor wholesale, and the markup-geometry problem returns | the shipping editor |
| Abandon entirely | loses the conflict/data-loss work, which fixed real bugs | nothing |

Codex recommends the second: keep the codec and session foundations, rebuild the
editor boundary and lifecycle behind the disabled flag. Its reasoning: the
position and transaction model is the right shape, and images plus one-step AI
undo working in the real app is evidence for that.

## The process failure

Not "too few tests". The wrong kind, believed too much.

`editor.test.ts`'s "real keystroke" helper invokes ProseMirror's key handler
directly, and its typing helper dispatches a transaction. Neither touches
contenteditable, DOM selection, layout, or WebKit. Nine rounds of mutation testing
hardened conflict resolution and pending-append provenance while the editor could
not accept a paragraph break.

The repo already contained the answer. `Web/src/richtext/demo.tsx` is a bench whose
own comment reads: *"for judging the editor by feel, which is the only way this
particular problem has ever been judged correctly."* It was never run. `CLAUDE.md`
also names a GUI verification recipe for exactly this, and it was never run.

The gate before enabling should have been, in real WebKit:

1. Type, press Enter, wait through the autosave, keep typing.
2. Press Enter three times; confirm every blank line survives save and reload.
3. Drag-select in both directions; apply every inline format.
4. Click AI, source and capture provenance spans.
5. Leave a stream and reopen it, repeatedly.
6. Repeat at ~2,000 lines while profiling WebContent.

Item 1 would have found it in under a minute.
