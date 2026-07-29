import { baseKeymap, chainCommands, exitCode } from 'prosemirror-commands';
import { history, redo, undo } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';
import { DOMParser, Fragment, Slice, type ParseOptions, type Node as ProseNode } from 'prosemirror-model';

/**
 * prosemirror-model accepts `ruleFromNode` as a parse option but does not declare
 * it — prosemirror-view passes one in from its own clipboard code.
 */
type ClipboardParseOptions = ParseOptions & {
  ruleFromNode?: (node: Node) => { ignore?: boolean } | null;
};
import { EditorState, type Command } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
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
import { aiWritingHighlight } from './operations';
import { provenance } from './provenance';
import { normalizeForMarkdown } from './normalize';
import { BREAK_ATTRIBUTES, tickerSchema } from './schema';

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
  /** The document as markdown, in exactly the form a reload will give back. */
  getMarkdown(): string;
  /** Replace the whole document, as a reload does. Clears undo history. */
  setMarkdown(markdown: string): void;
  /** Append a fragment at the end of the document, as an external write does. */
  appendMarkdown(markdown: string): void;
  destroy(): void;
}

export interface RichTextEditorOptions {
  parent: HTMLElement;
  markdown: string;
  /** Fires only when the document actually changed, with the markdown to store. */
  onChange?: (markdown: string) => void;
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

function stateFor(doc: ProseNode): EditorState {
  // Order matters: our keymap gets first refusal, then the stock bindings.
  return EditorState.create({
    doc,
    plugins: [history(), tickerKeymap(), keymap(baseKeymap), aiWritingHighlight(), provenance()],
  });
}

export function createRichTextEditor(options: RichTextEditorOptions): RichTextEditor {
  const { parent, markdown, onChange, onOpenLink, onUpdate } = options;
  parent.classList.add('richtext-editor');

  /**
   * ponytail: normalising here rather than as a transaction on the live document.
   * Rewriting the doc under the cursor while someone types costs a selection remap
   * on every keystroke, and after the break rules were narrowed to what markdown
   * genuinely cannot express, the only thing left that a save can change is a break
   * sitting at the very end of a block — which disappears the moment anything is
   * typed after it. Revisit if a second divergence shows up.
   */
  const toMarkdown = (doc: ProseNode) => serializeMarkdown(normalizeForMarkdown(doc));

  const view = new EditorView(parent, {
    state: stateFor(parseMarkdown(markdown)),
    clipboardParser,

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
      if (transaction.docChanged) onChange?.(toMarkdown(next.doc));
      onUpdate?.();
    },
  });

  return {
    view,
    getMarkdown: () => toMarkdown(view.state.doc),

    setMarkdown(next: string) {
      view.updateState(stateFor(parseMarkdown(next)));
      onUpdate?.();
    },

    appendMarkdown(fragment: string) {
      const parsed = parseMarkdown(fragment);
      if (parsed.childCount === 0) return;
      const end = view.state.doc.content.size;
      // A whole-block insert at the very end: openStart/openEnd 0, so the blocks
      // arrive intact rather than being merged into the last paragraph.
      const slice = new Slice(Fragment.from(parsed.content), 0, 0);
      view.dispatch(view.state.tr.replace(end, end, slice).scrollIntoView());
    },

    destroy: () => view.destroy(),
  };
}
