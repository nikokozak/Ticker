import { EditorState, TextSelection } from 'prosemirror-state';
import { describe, expect, it } from 'vitest';
import {
  activeFormats,
  insertSoftBreak,
  toggleBlockquote,
  toggleBold,
  toggleBulletList,
  toggleHeading,
  toggleItalic,
  toggleUnderline,
} from './commands';
import { parseMarkdown, serializeMarkdown } from './markdown';
import type { Command } from 'prosemirror-state';

/**
 * These assert the property that the old editor could not hold: formatting is a
 * structural operation, so the markdown that comes out is always well formed.
 * `**bold*` and `****` are not reachable states.
 */

function stateFor(markdown: string, from: number, to = from): EditorState {
  const state = EditorState.create({ doc: parseMarkdown(markdown) });
  return state.apply(state.tr.setSelection(TextSelection.create(state.doc, from, to)));
}

/** Run a command and return the markdown it produces. */
function run(state: EditorState, command: Command): string {
  let next = state;
  command(state, (tr) => { next = state.apply(tr); });
  return serializeMarkdown(next.doc);
}

/** Select the given word in a single-paragraph document. */
function selectWord(markdown: string, word: string): EditorState {
  const doc = parseMarkdown(markdown);
  let found = -1;
  doc.descendants((node, pos) => {
    if (found < 0 && node.isText && node.text?.includes(word)) found = pos + (node.text.indexOf(word));
  });
  if (found < 0) throw new Error(`no "${word}" in ${markdown}`);
  const state = EditorState.create({ doc });
  return state.apply(state.tr.setSelection(TextSelection.create(doc, found, found + word.length)));
}

describe('inline formatting is structural, so the markdown is always well formed', () => {
  it('wraps and unwraps bold without ever producing stray markers', () => {
    const on = run(selectWord('one two three', 'two'), toggleBold);
    expect(on).toBe('one **two** three');
    expect(run(selectWord(on, 'two'), toggleBold)).toBe('one two three');
  });

  it('does the same for italic and underline', () => {
    expect(run(selectWord('one two three', 'two'), toggleItalic)).toBe('one *two* three');
    expect(run(selectWord('one two three', 'two'), toggleUnderline)).toBe('one <u>two</u> three');
  });

  it('nests marks without producing four asterisks', () => {
    // The exact failure that made the old editor unusable: selecting a partly
    // formatted range and toggling produced '****'. Marks cannot do this.
    const bold = run(selectWord('one two three', 'two'), toggleBold);
    const both = run(selectWord(bold, 'two'), toggleItalic);
    expect(both).toBe('one ***two*** three');
    expect(both).not.toMatch(/\*{4}/);
    expect(serializeMarkdown(parseMarkdown(both))).toBe(both);
  });

  it('cannot select half a delimiter, because delimiters are not in the document', () => {
    const doc = parseMarkdown('one **two** three');
    // Every position in the document is a content position; the '**' occupies none.
    expect(doc.textContent).toBe('one two three');
  });

  it('applies formatting across a partial word without corrupting neighbours', () => {
    const state = stateFor('alpha beta', 2, 5); // "lph"
    expect(run(state, toggleBold)).toBe('a**lph**a beta');
  });
});

describe('block formatting', () => {
  it('toggles a heading on and back off', () => {
    const on = run(selectWord('Title here', 'Title'), toggleHeading(2));
    expect(on).toBe('## Title here');
    expect(run(selectWord(on, 'Title'), toggleHeading(2))).toBe('Title here');
  });

  it('switches heading level rather than stacking markers', () => {
    const h2 = run(selectWord('Title', 'Title'), toggleHeading(2));
    expect(run(selectWord(h2, 'Title'), toggleHeading(3))).toBe('### Title');
  });

  it('toggles a bullet list on and off', () => {
    const on = run(selectWord('item one', 'item'), toggleBulletList);
    expect(on).toBe('* item one');
    expect(run(selectWord(on, 'item'), toggleBulletList)).toBe('item one');
  });

  it('toggles a blockquote on and off', () => {
    const on = run(selectWord('quoted text', 'quoted'), toggleBlockquote);
    expect(on).toBe('> quoted text');
    expect(run(selectWord(on, 'quoted'), toggleBlockquote)).toBe('quoted text');
  });
});

describe('soft break', () => {
  it('inserts a line break inside the paragraph, not a new one', () => {
    const state = stateFor('foo', 4); // end of "foo"
    const out = run(state, insertSoftBreak);
    expect(out).toBe('foo\n');
    expect(parseMarkdown(out).childCount).toBe(1); // still one paragraph
  });

  it('produces markdown that reloads as the same document', () => {
    const state = stateFor('foo bar', 4);
    const out = run(state, insertSoftBreak);
    expect(serializeMarkdown(parseMarkdown(out))).toBe(out);
  });
});

describe('activeFormats drives the selection menu', () => {
  it('reports the marks and block type under the selection', () => {
    expect(activeFormats(selectWord('a **bold** b', 'bold'))).toMatchObject({ bold: true, italic: false, heading: 0 });
    expect(activeFormats(selectWord('## Title', 'Title'))).toMatchObject({ heading: 2 });
    expect(activeFormats(selectWord('* item', 'item'))).toMatchObject({ bulletList: true });
    expect(activeFormats(selectWord('> quote', 'quote'))).toMatchObject({ blockquote: true });
    expect(activeFormats(selectWord('a <u>u</u> b', 'u'))).toMatchObject({ underline: true });
  });
});
