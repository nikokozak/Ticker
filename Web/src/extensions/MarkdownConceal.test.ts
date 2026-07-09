import { markdown } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { DecorationSet } from '@codemirror/view';
import { describe, expect, it } from 'vitest';
import { buildMarkdownConcealDecorations, revealRawLinksEffect } from './MarkdownConceal';
import { markdownConcealExtension } from './MarkdownConceal';

function viewFor(state: EditorState): EditorView {
  return {
    state,
    visibleRanges: [{ from: 0, to: state.doc.length }],
    viewport: { from: 0, to: state.doc.length },
  } as unknown as EditorView;
}

function stateWithSelection(doc: string, anchor: number): EditorState {
  return EditorState.create({
    doc,
    selection: { anchor },
    extensions: [markdown(), markdownConcealExtension],
  });
}

function concealRanges(decorations: DecorationSet, docLength: number): Array<[number, number]> {
  const ranges: Array<[number, number]> = [];
  decorations.between(0, docLength, (from, to) => {
    if (to > from) ranges.push([from, to]); // skip zero-length line decorations
  });
  return ranges;
}

describe('MarkdownConceal static concealment', () => {
  it('is completely independent of the selection', () => {
    const doc = '# Title\n\n**one** middle **two**';
    const positions = [0, 2, doc.indexOf('one'), doc.indexOf('middle'), doc.length];
    const results = positions.map((anchor) =>
      JSON.stringify(concealRanges(buildMarkdownConcealDecorations(viewFor(stateWithSelection(doc, anchor)), true), doc.length))
    );
    expect(new Set(results).size).toBe(1); // identical decorations for every caret position
    expect(JSON.parse(results[0]).length).toBe(5); // '# ' + 4 emphasis marks stay concealed
  });

  it('reveals the whole line raw via the explicit reveal effect', () => {
    const doc = '# Title\n\n**one** and **two**';
    const base = stateWithSelection(doc, doc.indexOf('one'));
    const boldLineFrom = base.doc.lineAt(doc.indexOf('one')).from;
    const revealed = base.update({ effects: revealRawLinksEffect.of(boldLineFrom) }).state;

    const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(revealed), true), doc.length);
    expect(ranges.filter(([from]) => from >= boldLineFrom)).toEqual([]); // raw line: nothing concealed
    expect(ranges.filter(([from]) => from < boldLineFrom).length).toBe(1); // heading elsewhere stays concealed
  });

  it('renders incomplete links fully raw (no conceal decorations)', () => {
    for (const doc of ['See [Safari]() here', 'See []() here', 'See [](https://x.com) here']) {
      const state = stateWithSelection(doc, 0);
      const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(state), true), doc.length);
      expect(ranges).toEqual([]);
    }
  });

  it('leaves chip-eligible http links to the chip layer but conceals complete ticker-pdf links', () => {
    const doc = '[Safari](https://apple.com) and [Book p.3](ticker-pdf://abc?page=3)';
    const state = stateWithSelection(doc, doc.length);
    const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(state), true), doc.length);

    const httpLinkEnd = doc.indexOf(')') + 1;
    expect(ranges.filter(([from]) => from < httpLinkEnd)).toEqual([]);

    const tickerStart = doc.indexOf('[Book');
    expect(ranges.filter(([from]) => from >= tickerStart).length).toBeGreaterThan(0);
  });
});
