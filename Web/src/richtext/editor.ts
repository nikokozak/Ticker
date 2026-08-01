import { baseKeymap, chainCommands, exitCode } from 'prosemirror-commands';
import { history, redo, undo } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';
import {
  DOMParser,
  Fragment,
  Slice,
  type Mark,
  type ParseOptions,
  type Node as ProseNode,
} from 'prosemirror-model';

/**
 * prosemirror-model accepts `ruleFromNode` as a parse option but does not declare
 * it — prosemirror-view passes one in from its own clipboard code.
 */
type ClipboardParseOptions = ParseOptions & {
  ruleFromNode?: (node: Node) => { ignore?: boolean } | null;
};
import { EditorState, type Command, type Transaction } from 'prosemirror-state';
import { EditorView, type NodeView } from 'prosemirror-view';
import {
  indentListItem,
  outdentListItem,
  splitListItemCommand,
  toggleBold,
  toggleCode,
  toggleItalic,
  toggleUnderline,
} from './commands';
import { parseMarkdown, serializeMarkdown } from './markdown';
import { aiWritingHighlight, setImageWidth } from './operations';
import {
  conversationAnchorField,
  isConversationDecorationTransaction,
  type ConversationAnchorFieldOptions,
} from './conversationAnchors';
import { provenance } from './provenance';
import { BREAK_ATTRIBUTES, MAX_IMAGE_WIDTH, MIN_IMAGE_WIDTH, tickerSchema } from './schema';

/**
 * The editor itself. The ProseMirror state is the live document; markdown exists
 * only at the two boundaries — parsed once on load, serialised on the way to disk.
 * Nothing in between knows the syntax exists, which is the whole point: there is no
 * markup in the document for a cursor to wander into.
 */

/**
 * Shift+Enter is a HARD break, not a soft one. Measured: `foo\ \ bar` round-trips
 * as two hard breaks, so pressing it twice genuinely leaves a blank line, whereas
 * two soft breaks are a blank line in markdown and end the paragraph. A hard break
 * also means "line break" to every other markdown reader, and markdown here is what
 * the AI and exports see, so an authored line break should say so.
 */
const insertHardBreak: Command = (state, dispatch) => {
  if (dispatch) {
    dispatch(state.tr.replaceSelectionWith(tickerSchema.nodes.hard_break.create()).scrollIntoView());
  }
  return true;
};

const INTERNAL_CLIPBOARD_TYPE = 'application/x-ticker-clipboard';
const INTERNAL_URL = /^ticker(?:-[a-z][a-z0-9-]*)?:\/\//i;
const BARE_INTERNAL_URL = /ticker(?:-[a-z][a-z0-9-]*)?:\/\/[^\s<>\])]+/gi;
let internalClipboard: { token: string; slice: Slice } | null = null;

function sanitizeInternalText(value: string): string {
  return value.replace(BARE_INTERNAL_URL, 'Ticker link');
}

function sanitizeAttributes(attrs: Readonly<Record<string, unknown>>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(attrs).map(([key, value]) => [
    key,
    typeof value === 'string' ? sanitizeInternalText(value) : value,
  ]));
}

/** Standard clipboard forms contain labels and text, never Ticker-private addresses. */
export function sanitizeTickerClipboardSlice(slice: Slice): Slice {
  const cleanMarks = (marks: readonly Mark[]) => marks.flatMap((mark) => {
    if (mark.type === tickerSchema.marks.link && INTERNAL_URL.test(String(mark.attrs.href))) return [];
    const attrs = sanitizeAttributes(mark.attrs);
    return [mark.type.create(attrs)];
  });
  const cleanNode = (node: ProseNode): ProseNode => {
    const marks = cleanMarks(node.marks);
    if (node.type === tickerSchema.nodes.image && INTERNAL_URL.test(String(node.attrs.src))) {
      return tickerSchema.text(sanitizeInternalText(String(node.attrs.alt || 'Image')), marks);
    }
    if (node.isText) return tickerSchema.text(sanitizeInternalText(node.text ?? ''), marks);
    const children: ProseNode[] = [];
    node.forEach((child) => children.push(cleanNode(child)));
    return node.type.create(sanitizeAttributes(node.attrs), Fragment.fromArray(children), marks);
  };
  const content: ProseNode[] = [];
  slice.content.forEach((node) => content.push(cleanNode(node)));
  return new Slice(Fragment.fromArray(content), slice.openStart, slice.openEnd);
}

function writeClipboard(view: EditorView, event: ClipboardEvent, cut: boolean): boolean {
  const data = event.clipboardData;
  const selection = view.state.selection;
  if (!data || selection.empty) return false;
  const original = selection.content();
  const serialized = view.serializeForClipboard(original);
  const token = crypto.randomUUID();
  internalClipboard = { token, slice: original };
  event.preventDefault();
  data.clearData();
  data.setData('text/html', serialized.dom.innerHTML);
  data.setData('text/plain', serialized.text);
  data.setData(INTERNAL_CLIPBOARD_TYPE, token);
  if (cut) {
    view.dispatch(view.state.tr.deleteSelection().scrollIntoView().setMeta('uiEvent', 'cut'));
  }
  return true;
}

function pasteInternalClipboard(view: EditorView, event: ClipboardEvent): boolean {
  const token = event.clipboardData?.getData(INTERNAL_CLIPBOARD_TYPE);
  if (!token || token !== internalClipboard?.token) return false;
  event.preventDefault();
  view.dispatch(view.state.tr
    .replaceSelection(internalClipboard.slice)
    .scrollIntoView()
    .setMeta('paste', true)
    .setMeta('uiEvent', 'paste'));
  return true;
}

function tickerKeymap() {
  return keymap({
    'Mod-z': undo,
    'Shift-Mod-z': redo,
    'Mod-y': redo,
    'Mod-b': toggleBold,
    'Mod-i': toggleItalic,
    'Mod-u': toggleUnderline,
    'Mod-`': toggleCode,
    'Shift-Enter': chainCommands(exitCode, insertHardBreak),
    // Before baseKeymap's Enter, and a no-op outside a list.
    Enter: splitListItemCommand,
    Tab: indentListItem,
    'Shift-Tab': outdentListItem,
  });
}

export interface RichTextEditor {
  readonly view: EditorView;
  /** The canonical document snapshot stored in stream_documents.doc_json. */
  getDocumentJSON(): string;
  /** Replace the whole document from its canonical snapshot. Clears undo history. */
  setDocumentJSON(docJSON: string): void;
  /** A derived markdown projection. Reading it must never rewrite the live document. */
  getMarkdownProjection(): string;
  /** Insert a markdown fragment at the current selection as one undo step. */
  insertMarkdown(markdown: string): void;
  /**
   * Append a fragment at the end of the document, as an external write does, and
   * report where it landed so metadata can be placed inside it.
   */
  appendMarkdown(markdown: string): { from: number; to: number };
  destroy(): void;
}

export interface RichTextEditorOptions {
  parent: HTMLElement;
  docJSON: string;
  /** Fires only when the document actually changed. */
  onChange?: () => void;
  /**
   * A click on a link. Nothing navigates on its own — a `ticker-pdf://` citation
   * has to reach the PDF pane and an external URL has to leave the WKWebView, and
   * both of those are the host's call, not the editor's.
   */
  onOpenLink?: (href: string) => void;
  /**
   * Fires after every transaction, including one that only moved the cursor. A
   * selection menu needs this: which buttons are lit depends on the selection, not
   * on the document.
   */
  onUpdate?: () => void;
  /**
   * Positions held outside editor state must see every mapping or the next edit
   * can apply metadata to text that moved while an async host action was open.
   */
  onTransaction?: (transaction: Transaction) => void;
  conversations?: ConversationAnchorFieldOptions;
}

/** The href of a link at this position, if there is one. */
function linkAt(state: EditorState, pos: number): string | null {
  const $pos = state.doc.resolve(pos);
  const mark = tickerSchema.marks.link.isInSet($pos.marks());
  return mark ? String(mark.attrs.href) : null;
}

/**
 * A clipboard parser that does not throw away a break at the end of a copied
 * selection.
 *
 * prosemirror-view hard-codes a `ruleFromNode` that ignores any trailing `<br>`,
 * because a contenteditable browser adds one as padding at the end of a block. That
 * heuristic is right for foreign HTML and wrong for our own: copying "one" plus the
 * line break after it pasted just "one", for soft and hard breaks alike.
 *
 * The option is passed to parseSlice, so it cannot be overridden by rules — but
 * parseSlice is called on THIS object, so it can be wrapped. Our breaks carry a data
 * attribute; a browser's padding `<br>` does not, and is still ignored.
 */
class TickerClipboardParser extends DOMParser {
  parseSlice(dom: HTMLElement, options: ClipboardParseOptions = {}): Slice {
    const inherited = options.ruleFromNode;
    const wrapped: ClipboardParseOptions = {
      ...options,
      ruleFromNode: (node: Node) => {
        const element = node as HTMLElement;
        if (element.nodeName === 'BR' && BREAK_ATTRIBUTES.some((name) => element.hasAttribute?.(name))) return null;
        return inherited ? inherited(node) : null;
      },
    };
    return super.parseSlice(dom, wrapped);
  }
}

const clipboardParser = new TickerClipboardParser(tickerSchema, DOMParser.fromSchema(tickerSchema).rules);

function imageView(node: ProseNode, view: EditorView, getPos: () => number | undefined): NodeView {
  const dom = document.createElement('span');
  dom.className = 'richtext-image';
  dom.contentEditable = 'false';

  const image = document.createElement('img');
  const handle = document.createElement('button');
  handle.type = 'button';
  handle.className = 'richtext-image-resize-handle';
  handle.title = 'Resize image';
  handle.setAttribute('aria-label', 'Resize image');
  dom.append(image, handle);

  const render = () => {
    image.setAttribute('src', String(node.attrs.src));
    image.setAttribute('alt', String(node.attrs.alt ?? ''));
    if (node.attrs.title) image.setAttribute('title', String(node.attrs.title));
    else image.removeAttribute('title');
    if (node.attrs.width) image.setAttribute('width', String(node.attrs.width));
    else image.removeAttribute('width');
    image.style.removeProperty('width');
  };
  render();

  handle.onmousedown = (event) => {
    if (!view.editable) return;
    event.preventDefault();
    event.stopPropagation();

    const startX = event.clientX;
    const startWidth = Number(node.attrs.width) || image.getBoundingClientRect().width;
    let width = Math.max(MIN_IMAGE_WIDTH, Math.min(MAX_IMAGE_WIDTH, Math.round(startWidth)));
    let moved = false;

    const move = (next: MouseEvent) => {
      moved = true;
      width = Math.max(MIN_IMAGE_WIDTH, Math.min(
        MAX_IMAGE_WIDTH,
        Math.round(startWidth + next.clientX - startX),
      ));
      image.style.width = `${width}px`;
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      if (!moved) {
        image.style.removeProperty('width');
        return;
      }
      const pos = getPos();
      if (pos !== undefined) setImageWidth(view, pos, width);
    };

    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };

  return {
    dom,
    update(next) {
      node = next;
      render();
      return true;
    },
  };
}

function stateFor(doc: ProseNode, conversations?: ConversationAnchorFieldOptions): EditorState {
  // Order matters: our keymap gets first refusal, then the stock bindings.
  return EditorState.create({
    doc,
    plugins: [history(), tickerKeymap(), keymap(baseKeymap), aiWritingHighlight(), provenance(), conversationAnchorField(conversations)],
  });
}

export function createRichTextEditor(options: RichTextEditorOptions): RichTextEditor {
  const {
    parent,
    docJSON,
    onChange,
    onOpenLink,
    onTransaction,
    onUpdate,
    conversations,
  } = options;
  parent.classList.add('richtext-editor');

  const view = new EditorView(parent, {
    state: stateFor(tickerSchema.nodeFromJSON(JSON.parse(docJSON)), conversations),
    clipboardParser,
    nodeViews: { image: imageView },
    transformCopied: sanitizeTickerClipboardSlice,
    handleDOMEvents: {
      copy: (current, event) => writeClipboard(current, event as ClipboardEvent, false),
      cut: (current, event) => writeClipboard(current, event as ClipboardEvent, true),
      paste: (current, event) => pasteInternalClipboard(current, event as ClipboardEvent),
    },

    /**
     * One plain click opens a link. The old editor made this ambiguous — the URL
     * was visible text you could also put a cursor in — and it was the single
     * biggest complaint about reading a stream with citations in it.
     */
    handleClick(_view, pos) {
      const href = linkAt(view.state, pos);
      if (!href || !onOpenLink) return false;
      onOpenLink(href);
      return true;
    },

    dispatchTransaction(transaction) {
      const next = view.state.apply(transaction);
      view.updateState(next);
      if (transaction.docChanged) onChange?.();
      onTransaction?.(transaction);
      if (!isConversationDecorationTransaction(transaction)) onUpdate?.();
    },
  });

  return {
    view,

    getDocumentJSON() {
      return JSON.stringify(view.state.doc.toJSON());
    },

    setDocumentJSON(next: string) {
      view.updateState(stateFor(tickerSchema.nodeFromJSON(JSON.parse(next)), conversations));
      onUpdate?.();
    },

    getMarkdownProjection() {
      return serializeMarkdown(view.state.doc);
    },

    insertMarkdown(markdown: string) {
      const parsed = parseMarkdown(markdown);
      if (parsed.childCount === 0) return;
      const slice = new Slice(Fragment.from(parsed.content), 0, 0);
      view.dispatch(view.state.tr.replaceSelection(slice).scrollIntoView());
    },

    appendMarkdown(fragment: string) {
      const parsed = parseMarkdown(fragment);
      if (parsed.childCount === 0) return { from: 0, to: 0 };
      const end = view.state.doc.content.size;
      // A whole-block insert at the very end: openStart/openEnd 0, so the blocks
      // arrive intact rather than being merged into the last paragraph.
      const slice = new Slice(Fragment.from(parsed.content), 0, 0);
      const tr = view.state.tr.replace(end, end, slice);
      view.dispatch(tr.scrollIntoView());
      // Where the fragment landed, so a caller can place metadata inside it. The
      // inserted blocks keep their internal structure, so a position measured
      // inside the parsed fragment is this base plus that position.
      return { from: end, to: view.state.doc.content.size };
    },

    destroy: () => view.destroy(),
  };
}
