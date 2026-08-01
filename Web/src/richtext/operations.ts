import { Plugin, PluginKey, Selection, TextSelection, type EditorState, type Transaction } from 'prosemirror-state';
import { closeHistory } from 'prosemirror-history';
import { Decoration, DecorationSet, type EditorView } from 'prosemirror-view';
import { Fragment, Slice, type Mark, type Node as ProseNode } from 'prosemirror-model';
import { parseTickerPDFURL } from '../extensions/PDFHighlightLink';
import { parseMarkdown } from './markdown';
import { addProvenanceSpans, hashProvenanceText } from './provenance';
import { ASSET_URL_PREFIX, isValidImageWidth, tickerSchema } from './schema';

/**
 * The operations the app performs ON the editor — AI writing, image insertion,
 * scrolling to a search hit. They live here rather than in the component so the
 * component is left with wiring, and so each one has a test.
 *
 * The rule they all obey: one user-visible action is ONE transaction, so it is one
 * undo step. The old editor lost this repeatedly, because an operation assembled
 * from several dispatches is several undos.
 */

/* AI writing ------------------------------------------------------------ */

const aiWritingKey = new PluginKey<DecorationSet>('tickerAIWriting');

/** Mark a range as AI-written; passing null clears the highlight. */
export const setAIWritingRange = (tr: Transaction, range: { from: number; to: number } | null): Transaction =>
  tr.setMeta(aiWritingKey, range);

/**
 * Highlights what the AI just wrote. A DECORATION rather than a mark, deliberately:
 * it must not be part of the document, or it would serialise into the markdown and
 * become the very thing this rewrite removes — invisible state the user can edit.
 *
 * ProseMirror maps the range through every later transaction, so typing inside the
 * highlight shrinks or splits it correctly. The old editor's version reported the
 * wrong range after edits because it tracked offsets by hand.
 */
export function aiWritingHighlight(): Plugin<DecorationSet> {
  return new Plugin<DecorationSet>({
    key: aiWritingKey,
    state: {
      init: () => DecorationSet.empty,
      apply(tr, current) {
        const meta = tr.getMeta(aiWritingKey) as { from: number; to: number } | null | undefined;
        if (meta === null) return DecorationSet.empty;
        if (meta) {
          return DecorationSet.create(tr.doc, [
            Decoration.inline(meta.from, meta.to, { class: 'richtext-ai-written' }),
          ]);
        }
        return current.map(tr.mapping, tr.doc);
      },
    },
    props: {
      decorations: (state) => aiWritingKey.getState(state),
    },
  });
}

/** The range currently highlighted as AI-written, if any. */
export function aiWritingRange(state: EditorState): { from: number; to: number } | null {
  const set = aiWritingKey.getState(state);
  const found = set?.find();
  return found?.length ? { from: found[0].from, to: found[0].to } : null;
}

/**
 * Replace a range with markdown the AI produced, as ONE undo step, and highlight
 * what landed. Returns the inserted range so a caller can scroll to it.
 *
 * Inline when the AI produced a single paragraph and the target sits inside one —
 * rewriting a sentence must not turn it into its own block. Otherwise the blocks go
 * in whole.
 */
export function applyAIMarkdown(
  view: EditorView,
  range: { from: number; to: number },
  markdown: string,
  options: { addToHistory?: boolean; historyGroup?: 'start' | 'continue' } = {},
): { from: number; to: number } {
  const parsed = parseMarkdown(markdown);
  const inline = parsed.childCount === 1
    && parsed.firstChild?.type === tickerSchema.nodes.paragraph
    && view.state.doc.resolve(range.from).parent.isTextblock;

  const content = inline ? parsed.firstChild!.content : parsed.content;
  const slice = new Slice(Fragment.from(content), 0, 0);

  const tr = view.state.tr.replaceRange(range.from, range.to, slice);
  const to = tr.mapping.map(range.to, 1);
  setAIWritingRange(tr, { from: range.from, to });
  if (options.historyGroup) {
    // A stream can outlast ProseMirror's time window. One fixed time keeps every
    // reparse in its undo event; closing the first keeps adjacent user typing out.
    tr.setTime(1);
    if (options.historyGroup === 'start') closeHistory(tr);
  }
  if (options.addToHistory === false) tr.setMeta('addToHistory', false);
  view.dispatch(tr.scrollIntoView());
  return { from: range.from, to };
}

/**
 * A streaming AI reply, applied to the document as it arrives.
 *
 * Chunks cannot be parsed independently: a stream splits wherever it likes, so
 * `**bo` and `ld**` each parse to plain text and neither is bold. The same goes for
 * a link split across its bracket, a list split mid-marker, a fence split mid-open.
 * So every chunk reparses the WHOLE accumulated buffer and replaces what the last
 * one wrote — correct at every frame rather than only at the end.
 *
 * Every reparse joins one isolated history event, so accepting a streamed reply is
 * still one undo step however many frames it took.
 */
export function streamAIMarkdown(view: EditorView, range: { from: number; to: number }) {
  const editable = view.props.editable;
  // A foreign edit makes both the saved range and its history group untrustworthy.
  // Refusing DOM edits while the stream owns that range removes both races.
  view.setProps({ editable: () => false });
  let buffer = '';
  let written = { from: range.from, to: range.to };
  let started = false;

  const write = (markdown: string) => {
    buffer = markdown;
    // ponytail: history stores one transform per chunk; add event squashing only
    // if long replies make that memory cost measurable.
    written = applyAIMarkdown(view, written, buffer, {
      historyGroup: started ? 'continue' : 'start',
    });
    started = true;
  };

  return {
    push(chunk: string): void {
      write(buffer + chunk);
    },
    finalize(markdown: string): void {
      write(markdown);
    },
    /** Finish, leaving exactly one undoable step behind. */
    done(): { from: number; to: number } {
      view.setProps({ editable });
      return written;
    },
    get markdown(): string {
      return buffer;
    },
  };
}

/** Insert one conversation answer as blocks, with its AI provenance, in one undo step. */
export function promoteConversationMarkdown(
  view: EditorView,
  pos: number,
  markdown: string,
  attribution: { requestId: string; model?: string | null; verb: string },
): { from: number; to: number } {
  const { tr, inserted } = markdownBlockInsertion(view, pos, markdown);
  addProvenanceSpans(setAIWritingRange(tr, inserted), [{
    spanId: crypto.randomUUID(),
    ...inserted,
    origin: 'ai',
    requestId: attribution.requestId,
    meta: { model: attribution.model ?? null, verb: attribution.verb },
    textHash: hashProvenanceText(tr.doc, inserted),
    createdAt: Date.now(),
  }]);
  view.dispatch(tr.scrollIntoView());
  return inserted;
}

function markdownBlockInsertion(view: EditorView, pos: number, markdown: string) {
  const parsed = parseMarkdown(markdown);
  if (parsed.childCount === 0) throw new Error('There is no content to add.');
  const from = Math.max(0, Math.min(pos, view.state.doc.content.size));
  return {
    tr: view.state.tr.replace(from, from, new Slice(Fragment.from(parsed.content), 0, 0)),
    inserted: { from, to: from + parsed.content.size },
  };
}

/** Insert explicit user-authored markdown as intact blocks in one undo step. */
export function insertMarkdownBlocks(
  view: EditorView,
  pos: number,
  markdown: string,
): { from: number; to: number } {
  const { tr, inserted } = markdownBlockInsertion(view, pos, markdown);
  view.dispatch(tr.scrollIntoView());
  return inserted;
}

/* Images ---------------------------------------------------------------- */

/**
 * Insert an image at the cursor as one step. The width is an attribute, so there is
 * no `{width=N}` text beside it for a cursor to land in — that token only ever
 * exists in the derived Markdown projection.
 */
export function insertImage(
  view: EditorView,
  attrs: { src: string; alt?: string | null; width?: number | null },
): void {
  if (attrs.width != null && (!isValidImageWidth(attrs.width) || !attrs.src.startsWith(ASSET_URL_PREFIX))) {
    throw new Error('Only ticker-asset images may carry a valid width.');
  }
  const image = tickerSchema.nodes.image.create({
    src: attrs.src,
    alt: attrs.alt ?? null,
    title: null,
    width: attrs.width ?? null,
  });
  view.dispatch(view.state.tr.replaceSelectionWith(image).scrollIntoView());
}

/** Resize an image already in the document, as one step. */
export function setImageWidth(view: EditorView, pos: number, width: number | null): void {
  const node = view.state.doc.nodeAt(pos);
  if (node?.type !== tickerSchema.nodes.image) return;
  if (width != null && !isValidImageWidth(width)) return;
  view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, { ...node.attrs, width }));
}

/* Finding text ---------------------------------------------------------- */

/**
 * The document as one flat string, with a position for every character.
 *
 * Searching node by node does not work: a mark boundary splits the text, so
 * "quick brown" is not found in `*quick* brown` even though the reader sees exactly
 * that. Flattening first is the only way to search what is on the screen.
 */
function flattenText(doc: ProseNode): { text: string; starts: number[]; ends: number[] } {
  let text = '';
  // Every character needs BOTH boundaries. One array cannot serve as each: the
  // position after the last character of a paragraph is inside that paragraph,
  // while the position before the first character of the next one is inside THAT
  // paragraph, and they are different numbers. Selecting from a start to the next
  // entry's start crosses a block boundary and ProseMirror rejects the endpoint.
  const starts: number[] = [];
  const ends: number[] = [];

  doc.descendants((node: ProseNode, pos: number) => {
    if (node.isText && node.text) {
      for (let i = 0; i < node.text.length; i += 1) {
        starts.push(pos + i);
        ends.push(pos + i + 1);
      }
      text += node.text;
    } else if (node.isLeaf && node.type.spec.leafText) {
      // A line break reads as a space when searching across it.
      starts.push(pos);
      ends.push(pos + node.nodeSize);
      text += ' ';
    } else if (node.isBlock && text && !text.endsWith(' ')) {
      // A synthetic space for the gap between blocks. It has no width, so both of
      // its boundaries stay on the side of the text that precedes it.
      const previous = ends.length ? ends[ends.length - 1] : pos;
      starts.push(previous);
      ends.push(previous);
      text += ' ';
    }
    return true;
  });

  return { text, starts, ends };
}

/**
 * Select the first occurrence of some text and scroll to it — what arriving from a
 * search result does.
 *
 * It searches the DOCUMENT's text, not the markdown, which is the point: a hit for
 * "bold" must not be found inside a `**` the user cannot see, and a match must not
 * be thrown off by syntax sitting between two words.
 */
export function selectText(view: EditorView, needle: string): boolean {
  if (!needle) return false;

  const { text, starts, ends } = flattenText(view.state.doc);
  const index = text.toLowerCase().indexOf(needle.toLowerCase());
  if (index < 0) return false;

  const from = starts[index];
  const to = ends[Math.min(index + needle.length - 1, ends.length - 1)];
  const selection = TextSelection.create(view.state.doc, from, to);
  view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
  view.focus();
  return true;
}

function pdfHighlightMark(
  node: ProseNode,
  highlightId: string,
  sourceId?: string,
): Mark | null {
  const expectedHighlight = highlightId.trim().toLowerCase();
  const expectedSource = sourceId?.trim().toLowerCase();
  if (!node.isText || !expectedHighlight) return null;

  const mark = tickerSchema.marks.link.isInSet(node.marks);
  const href = mark?.attrs.href;
  if (typeof href !== 'string' || !href.startsWith('ticker-pdf://')) return null;

  const destination = parseTickerPDFURL(href);
  if (
    destination?.highlightId?.toLowerCase() !== expectedHighlight
    || (
      expectedSource
      && destination.sourceId
      && destination.sourceId.toLowerCase() !== expectedSource
    )
  ) return null;
  return mark ?? null;
}

export interface SelectedPDFHighlight {
  highlightId: string;
  sourceId?: string;
}

/** The first document link for a persisted PDF highlight. */
export function pdfHighlightRange(
  state: EditorState,
  sourceId: string,
  highlightId: string,
): { from: number; to: number } | null {
  let found: { from: number; to: number } | null = null;
  state.doc.descendants((node, pos) => {
    if (found || !pdfHighlightMark(node, highlightId, sourceId)) return !found;
    found = { from: pos, to: pos + node.nodeSize };
    return false;
  });
  return found;
}

/** The one persisted PDF highlight touched by the current selection, if any. */
export function selectedPDFHighlight(state: EditorState): SelectedPDFHighlight | null {
  const { from, to, empty } = state.selection;
  if (empty) return null;

  const found = new Map<string, SelectedPDFHighlight>();
  state.doc.nodesBetween(from, to, (node) => {
    if (!node.isText) return;
    const mark = tickerSchema.marks.link.isInSet(node.marks);
    const href = mark?.attrs.href;
    if (typeof href !== 'string') return;
    const destination = parseTickerPDFURL(href);
    if (!destination?.highlightId) return;
    const key = `${destination.sourceId?.toLowerCase() ?? ''}\u0000${destination.highlightId.toLowerCase()}`;
    found.set(key, {
      highlightId: destination.highlightId,
      sourceId: destination.sourceId,
    });
  });

  return found.size === 1 ? found.values().next().value ?? null : null;
}

/** Remove every document link to one deleted PDF highlight without removing text. */
export function removePDFHighlightLink(
  view: EditorView,
  highlightId: string,
  sourceId?: string,
): boolean {
  let found = false;
  const tr = view.state.tr;
  view.state.doc.descendants((node, pos) => {
    const mark = pdfHighlightMark(node, highlightId, sourceId);
    if (!mark) return true;
    tr.removeMark(pos, pos + node.nodeSize, mark);
    found = true;
    return true;
  });

  if (!found) return false;
  tr.setMeta('addToHistory', false);
  view.dispatch(tr);
  return true;
}

/** Select and scroll to the first rich-text link for a persisted PDF highlight. */
export function revealPDFHighlight(
  view: EditorView,
  sourceId: string,
  highlightId: string,
): boolean {
  const range = pdfHighlightRange(view.state, sourceId, highlightId);
  if (!range) return false;
  view.dispatch(
    view.state.tr
      .setSelection(TextSelection.create(view.state.doc, range.from, range.to))
      .setMeta('addToHistory', false)
      .scrollIntoView(),
  );
  view.focus();
  return true;
}

/**
 * Put the cursor at the end of the document — what clicking below the text does.
 *
 * Selection.atEnd, not position doc.content.size: that position is AFTER the last
 * paragraph rather than inside it, so anything inserted there became its own block
 * instead of continuing the last line.
 */
export function focusAtEnd(view: EditorView): void {
  view.dispatch(view.state.tr.setSelection(Selection.atEnd(view.state.doc)).scrollIntoView());
  view.focus();
}
