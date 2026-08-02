// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { TextSelection } from 'prosemirror-state';
import type { Node as ProseNode, ResolvedPos, Slice } from 'prosemirror-model';
import type { EditorView } from 'prosemirror-view';
import * as prosemirrorView from 'prosemirror-view';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';

/**
 * The real paste entry point. `parseSlice` alone ignores the `data-pm-slice` depths
 * the copy wrote, so a copied block would merge into the paragraph it landed in.
 * prosemirror-view exports this but does not declare it.
 */
const parseFromClipboard = (prosemirrorView as unknown as {
  __parseFromClipboard: (
    view: EditorView, text: string, html: string | null, plainText: boolean, context: ResolvedPos,
  ) => Slice | null;
}).__parseFromClipboard;

/**
 * These drive the real EditorView, not a stub. Earlier work in this repo tested a
 * fake `{state, visibleRanges}` object and proved nothing about what a cursor
 * actually does, which is how the bugs that started this rewrite got through.
 *
 * Everything here goes through a keystroke, a paste, or a transaction — the same
 * paths a user takes.
 */

let editor: RichTextEditor | null = null;

function open(markdown: string, onChange?: () => void): RichTextEditor {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  editor = createRichTextEditor({
    parent,
    docJSON: JSON.stringify(parseMarkdown(markdown).toJSON()),
    onChange,
  });
  return editor;
}

afterEach(() => {
  editor?.destroy();
  editor = null;
  document.body.innerHTML = '';
});

/** Send a keystroke the way the browser does, through the view's own handler. */
function press(ed: RichTextEditor, key: string, modifiers: Partial<KeyboardEvent> = {}): boolean {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers });
  return Boolean(ed.view.someProp('handleKeyDown', (handler) => handler(ed.view, event)));
}

/**
 * `Mod` is Cmd on a Mac and Ctrl elsewhere, and prosemirror-keymap decides from
 * navigator.platform — which jsdom leaves empty, so tests must send Ctrl.
 */
const MOD = { ctrlKey: true };

/** Put the cursor at a document position, or select a range. */
function place(ed: RichTextEditor, from: number, to = from): void {
  ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, from, to)));
}

/**
 * Position of a substring, counted the way ProseMirror counts — hand-arithmetic on
 * document positions is how test bugs get mistaken for product bugs.
 */
function find(ed: RichTextEditor, text: string, offset = 0): number {
  let at = -1;
  ed.view.state.doc.descendants((node, pos) => {
    if (at < 0 && node.isText && node.text?.includes(text)) at = pos + node.text.indexOf(text);
  });
  if (at < 0) throw new Error(`no ${JSON.stringify(text)} in ${ed.view.state.doc.toString()}`);
  return at + offset;
}

/** Put the cursor immediately after a substring. */
function after(ed: RichTextEditor, text: string): number {
  return find(ed, text, text.length);
}

function type(ed: RichTextEditor, text: string): void {
  ed.view.dispatch(ed.view.state.tr.insertText(text));
}

describe('the document survives the editor', () => {
  it('shows the empty-document placeholder until the user types', () => {
    const ed = open('');
    const block = ed.view.dom.querySelector('p')!;
    expect(block.dataset.placeholder).toBe('Start writing…');

    type(ed, 'Hello');
    expect(ed.view.dom.querySelector('[data-placeholder]')).toBe(null);
  });

  it('opens markdown and gives it back unchanged', () => {
    const source = '# Title\n\nSome **bold** and <u>underlined</u> text.\n\n* one\n* two';
    expect(open(source).getMarkdownProjection()).toBe(source);
  });

  it('reports a change only when the document actually changed', () => {
    let changes = 0;
    const ed = open('hello', () => { changes += 1; });
    place(ed, after(ed, 'hello'));
    expect(changes).toBe(0); // moving the cursor is not an edit
    type(ed, ' there');
    expect(changes).toBe(1);
    expect(ed.getMarkdownProjection()).toBe('hello there');
  });

  it('round-trips through a reload', () => {
    const ed = open('one');
    place(ed, after(ed, 'one'));
    type(ed, ' two');
    const saved = ed.getMarkdownProjection();
    ed.setDocumentJSON(JSON.stringify(parseMarkdown(saved).toJSON()));
    expect(ed.getMarkdownProjection()).toBe(saved);
    expect(ed.view.state.doc.textContent).toBe('one two');
  });

  it('round-trips blank paragraphs through document JSON', () => {
    const ed = open('one');
    place(ed, after(ed, 'one'));
    press(ed, 'Enter');
    press(ed, 'Enter');
    const saved = ed.getDocumentJSON();

    ed.setDocumentJSON(JSON.stringify(parseMarkdown('changed').toJSON()));
    ed.setDocumentJSON(saved);

    expect(ed.view.state.doc.childCount).toBe(3);
    expect(ed.view.state.doc.textContent).toBe('one');
  });
});

describe('there is no markup for the cursor to walk into', () => {
  // The bug that started the rewrite: arrowing through formatted text used to move
  // through hidden '**' characters, and Enter inside them exposed the tags.
  it('a bold word is exactly as many positions as its letters', () => {
    const ed = open('one **two** three');
    expect(ed.view.state.doc.textContent).toBe('one two three');
    // Walking every position and back must never land "inside" a delimiter,
    // because the delimiters are not in the document at all.
    const size = ed.view.state.doc.content.size;
    for (let pos = 1; pos < size; pos += 1) {
      place(ed, pos);
      expect(ed.view.state.selection.from).toBe(pos);
    }
  });

  it('typing at the edge of bold text cannot produce a stray marker', () => {
    const ed = open('one **two** three');
    place(ed, find(ed, 'two', 1)); // between the 't' and the 'w'
    type(ed, 'X');
    expect(ed.getMarkdownProjection()).toBe('one **tXwo** three');
    expect(ed.getMarkdownProjection()).not.toMatch(/\*{3}/);
  });

  it('Enter inside formatted text splits the paragraph, not the formatting', () => {
    const ed = open('**bold text**');
    place(ed, after(ed, 'bold')); // between the word and the space
    expect(press(ed, 'Enter')).toBe(true);
    expect(ed.view.state.doc.childCount).toBe(2);
    expect(ed.view.state.doc.child(0).textContent).toBe('bold');
    expect(ed.view.state.doc.child(1).textContent).toBe(' text');
  });
});

describe('keystrokes', () => {
  it('reading the markdown projection does not delete a paragraph break', () => {
    const ed = open('foo');
    place(ed, after(ed, 'foo'));
    expect(press(ed, 'Enter')).toBe(true);
    expect(ed.view.state.doc.childCount).toBe(2);

    ed.getMarkdownProjection();

    expect(ed.view.state.doc.childCount).toBe(2);
    expect(press(ed, 'Enter')).toBe(true);
    ed.getMarkdownProjection();
    expect(ed.view.state.doc.childCount).toBe(3);
    expect(ed.view.state.selection.$from.parentOffset).toBe(0);
  });

  it('Shift+Enter makes a line break inside the paragraph', () => {
    const ed = open('foo');
    place(ed, after(ed, 'foo'));
    expect(press(ed, 'Enter', { shiftKey: true })).toBe(true);
    type(ed, 'bar');
    expect(ed.view.state.doc.childCount).toBe(1); // still ONE paragraph
    expect(ed.getMarkdownProjection()).toBe('foo\\\nbar');
  });

  it('Shift+Enter twice leaves a blank line instead of collapsing', () => {
    const ed = open('foo');
    place(ed, after(ed, 'foo'));
    press(ed, 'Enter', { shiftKey: true });
    press(ed, 'Enter', { shiftKey: true });
    type(ed, 'bar');
    const saved = ed.getMarkdownProjection();
    ed.setDocumentJSON(JSON.stringify(parseMarkdown(saved).toJSON()));
    expect(ed.getMarkdownProjection()).toBe(saved);
    expect(ed.view.state.doc.firstChild?.childCount).toBe(4); // text, br, br, text
  });

  it('Enter splits a list item instead of the paragraph inside it', () => {
    const ed = open('* one');
    place(ed, after(ed, 'one'));
    expect(press(ed, 'Enter')).toBe(true);
    type(ed, 'two');
    expect(ed.getMarkdownProjection()).toBe('* one\n* two');
  });

  it('Tab and Shift+Tab indent and outdent a list item', () => {
    const ed = open('* one\n* two');
    place(ed, after(ed, 'two'));
    expect(press(ed, 'Tab')).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('* one\n  * two');
    expect(press(ed, 'Tab', { shiftKey: true })).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('* one\n* two');
  });

  it('Tab does nothing outside a list, rather than eating the keystroke', () => {
    const ed = open('plain');
    place(ed, after(ed, 'plain'));
    expect(press(ed, 'Tab')).toBe(false);
  });

  it('Mod+B bolds the selection and Mod+B again removes it', () => {
    const ed = open('one two three');
    place(ed, find(ed, 'two'), after(ed, 'two'));
    expect(press(ed, 'b', MOD)).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('one **two** three');
    place(ed, find(ed, 'two'), after(ed, 'two'));
    press(ed, 'b', MOD);
    expect(ed.getMarkdownProjection()).toBe('one two three');
  });

  it('undo restores the previous document in one step', () => {
    const ed = open('one two three');
    place(ed, find(ed, 'two'), after(ed, 'two'));
    press(ed, 'b', MOD);
    expect(ed.getMarkdownProjection()).toBe('one **two** three');
    expect(press(ed, 'z', MOD)).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('one two three');
  });
});

describe('copy and paste inside the editor', () => {
  /**
   * The real path. ProseMirror puts a slice on the clipboard as HTML and parses
   * HTML back even for a same-editor paste, so anything the schema's DOM rules
   * cannot express is lost here and nowhere else. The wrapper element carries the
   * `data-pm-slice` that records the open depths, so it is handed to the parser
   * whole rather than through innerHTML.
   */
  function copy(ed: RichTextEditor, from: number, to: number): { html: string; text: string } {
    const { dom, text } = ed.view.serializeForClipboard(ed.view.state.doc.slice(from, to));
    return { html: (dom as HTMLElement).innerHTML, text };
  }

  function paste(ed: RichTextEditor, clipboard: { html: string; text: string }, target: number): Slice {
    place(ed, target);
    const slice = parseFromClipboard(
      ed.view,
      clipboard.text,
      clipboard.html,
      false,
      ed.view.state.selection.$from,
    );
    if (!slice) throw new Error('the clipboard produced nothing');
    ed.view.dispatch(ed.view.state.tr.replaceSelection(slice));
    return slice;
  }

  /** The node kinds produced by copying the whole first paragraph and pasting it. */
  function pastedKinds(ed: RichTextEditor): string[] {
    const clipboard = copy(ed, find(ed, 'one'), after(ed, 'two'));
    place(ed, after(ed, 'two'));
    const slice = parseFromClipboard(ed.view, clipboard.text, clipboard.html, false, ed.view.state.selection.$from);
    const names: string[] = [];
    slice?.content.descendants((node: ProseNode) => { names.push(node.type.name); });
    return names;
  }

  function clipboardEvent(type: 'copy' | 'paste', values = new Map<string, string>()) {
    const event = new Event(type, { bubbles: true, cancelable: true }) as ClipboardEvent;
    Object.defineProperty(event, 'clipboardData', {
      value: {
        clearData: () => values.clear(),
        getData: (format: string) => values.get(format) ?? '',
        setData: (format: string, value: string) => { values.set(format, value); },
      },
    });
    return { event, values };
  }

  it('keeps formatting when a formatted phrase is copied', () => {
    const ed = open('a **bold** b');
    const clipboard = copy(ed, find(ed, 'bold'), after(ed, 'bold'));
    paste(ed, clipboard, after(ed, ' b'));
    expect(ed.getMarkdownProjection()).toBe('a **bold** b**bold**');
  });

  it('keeps a line break as the same kind of break', () => {
    const ed = open('one\ntwo');
    expect(ed.view.state.doc.firstChild?.child(1).type.name).toBe('soft_break');

    expect(pastedKinds(ed)).toContain('soft_break');
    expect(pastedKinds(ed)).not.toContain('hard_break');
  });

  it('keeps a hard break distinct from a soft one', () => {
    const ed = open('one\\\ntwo');
    expect(pastedKinds(ed)).toContain('hard_break');
    expect(pastedKinds(ed)).not.toContain('soft_break');
  });

  it('keeps a break at the very END of the copied selection', () => {
    // A contenteditable browser adds a padding <br> at the end of a block, so
    // ProseMirror ignores a trailing one — which silently ate a real break whenever
    // a selection ended on it. Both kinds were affected.
    for (const [markdown, kind] of [['one\ntwo', 'soft_break'], ['one\\\ntwo', 'hard_break']] as Array<[string, string]>) {
      const ed = open(markdown);
      const clipboard = copy(ed, find(ed, 'one'), after(ed, 'one') + 1); // "one" + the break
      place(ed, after(ed, 'two'));
      const slice = parseFromClipboard(ed.view, clipboard.text, clipboard.html, false, ed.view.state.selection.$from);
      const names: string[] = [];
      slice?.content.descendants((node: ProseNode) => { names.push(node.type.name); });
      expect(names, `${kind} lost at the end of a copied selection`).toContain(kind);
    }
  });

  it('keeps a whole list, with its numbering and its tightness', () => {
    const ed = open('3. three\n4. four\n\nafter');
    const clipboard = copy(ed, 0, ed.view.state.doc.firstChild?.nodeSize ?? 0);
    paste(ed, clipboard, after(ed, 'after'));
    expect(ed.getMarkdownProjection()).toBe('3. three\n4. four\n\nafter\n\n3. three\n4. four');
  });

  it('keeps a code block language', () => {
    const ed = open('```ts\nconst x = 1;\n```\n\nafter');
    const clipboard = copy(ed, 0, ed.view.state.doc.firstChild?.nodeSize ?? 0);
    paste(ed, clipboard, after(ed, 'after'));
    expect(ed.getMarkdownProjection()).toBe('```ts\nconst x = 1;\n```\n\nafter\n\n```ts\nconst x = 1;\n```');
  });

  it('removes all Ticker-private addresses from standard clipboard forms', () => {
    const ed = open([
      '[PDF](ticker-pdf://source-1?page=2)',
      'ticker://open/private',
      '![Diagram](ticker-asset://stream/image.png)',
      '[Web](https://example.test)',
    ].join(' '));
    const { dom, text } = ed.view.serializeForClipboard(
      ed.view.state.doc.slice(0, ed.view.state.doc.content.size),
    );
    const html = (dom as HTMLElement).innerHTML;
    expect(html).not.toMatch(/ticker(?:-[a-z]+)?:\/\//i);
    expect(text).not.toMatch(/ticker(?:-[a-z]+)?:\/\//i);
    expect(html).toContain('PDF');
    expect(html).toContain('Diagram');
    expect(html).toContain('https://example.test');
  });

  it('preserves private links for an in-app paste without putting them on the public clipboard', () => {
    const ed = open('[PDF](ticker-pdf://source-1?page=2) then');
    place(ed, find(ed, 'PDF'), after(ed, 'PDF'));
    const clipboard = clipboardEvent('copy');
    ed.view.dom.dispatchEvent(clipboard.event);
    expect(clipboard.event.defaultPrevented).toBe(true);
    expect(clipboard.values.get('text/html')).not.toContain('ticker-pdf://');
    expect(clipboard.values.get('text/plain')).not.toContain('ticker-pdf://');
    expect([...clipboard.values.values()].some((value) => value.includes('ticker-pdf://'))).toBe(false);

    place(ed, after(ed, 'then'));
    ed.view.dom.dispatchEvent(clipboardEvent('paste', clipboard.values).event);
    expect(ed.getMarkdownProjection().match(/ticker-pdf:\/\/source-1/g)).toHaveLength(2);
  });
});

describe('links read as links', () => {
  // The complaint that redirected this whole rewrite: a citation URL expanded the
  // paragraph to five times its size, it was unclear how to click one, and it was
  // unclear how to make one. The href is no longer in the text at all.
  function openWithLinks(markdown: string): { ed: RichTextEditor; opened: string[] } {
    const opened: string[] = [];
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    editor = createRichTextEditor({
      parent,
      docJSON: JSON.stringify(parseMarkdown(markdown).toJSON()),
      onOpenLink: (href) => opened.push(href),
    });
    return { ed: editor, opened };
  }

  it('shows the label, never the URL, however long the URL is', () => {
    const ed = open('See [the paper](https://example.test/a/very/long/citation/url?with=query&more=params#frag).');
    expect(ed.view.state.doc.textContent).toBe('See the paper.');
  });

  it('takes up exactly as many positions as its label', () => {
    const ed = open('[label](ticker-pdf://s?page=3&q=a%20quote)');
    expect(ed.view.state.doc.content.size).toBe('label'.length + 2); // + the paragraph
  });

  it('opens on a single click, and reports the href to the host', () => {
    const { ed, opened } = openWithLinks('Read [the paper](https://example.test/x) now.');
    const pos = find(ed, 'the paper', 2);
    const handled = ed.view.someProp('handleClick', (fn) => fn(ed.view, pos, new MouseEvent('click')));
    expect(handled).toBe(true);
    expect(opened).toEqual(['https://example.test/x']);
  });

  it('leaves a click on ordinary text alone', () => {
    const { ed, opened } = openWithLinks('Read [the paper](https://example.test/x) now.');
    const handled = ed.view.someProp('handleClick', (fn) => fn(ed.view, find(ed, 'now'), new MouseEvent('click')));
    expect(handled).toBeFalsy();
    expect(opened).toEqual([]);
  });

  it('makes a citation out of a selection without anyone typing brackets', () => {
    const ed = open('Read the paper now.');
    const link = ed.view.state.schema.marks.link.create({ href: 'ticker-pdf://s?page=3', title: null });
    ed.view.dispatch(ed.view.state.tr.addMark(find(ed, 'the paper'), after(ed, 'the paper'), link));
    expect(ed.getMarkdownProjection()).toBe('Read [the paper](ticker-pdf://s?page=3) now.');
    expect(ed.view.state.doc.textContent).toBe('Read the paper now.'); // still no syntax
  });
});

describe('images', () => {
  it('renders at its stored width, with no width markup in the text', () => {
    const ed = open('![a shot](ticker-asset://s/a.png){width=300}');
    expect(ed.view.state.doc.textContent).toBe('');
    const img = ed.view.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('ticker-asset://s/a.png');
    expect(img?.getAttribute('width')).toBe('300');
    expect(ed.getMarkdownProjection()).toBe('![a shot](ticker-asset://s/a.png){width=300}');
  });

  it('renders without a width when it has none', () => {
    const ed = open('![a shot](ticker-asset://s/a.png)');
    expect(ed.view.dom.querySelector('img')?.hasAttribute('width')).toBe(false);
  });
});

describe('an external append', () => {
  // Ticker's one write primitive: the quick panel, AI and capture all append at the
  // end of the document and never rewrite it.
  it('adds blocks at the end without merging into the last paragraph', () => {
    const ed = open('first paragraph');
    ed.appendMarkdown('\n\n## Added\n\nsecond paragraph');
    expect(ed.view.state.doc.childCount).toBe(3);
    expect(ed.getMarkdownProjection()).toBe('first paragraph\n\n## Added\n\nsecond paragraph');
  });

  it('reports the appended document through onChange', () => {
    let changes = 0;
    const ed = open('one', () => { changes += 1; });
    ed.appendMarkdown('\n\ntwo');
    expect(changes).toBe(1);
    expect(ed.getMarkdownProjection()).toBe('one\n\ntwo');
  });

  it('is undoable as its own step and does not disturb the text before it', () => {
    const ed = open('one');
    ed.appendMarkdown('\n\ntwo');
    press(ed, 'z', MOD);
    expect(ed.getMarkdownProjection()).toBe('one');
  });
});
