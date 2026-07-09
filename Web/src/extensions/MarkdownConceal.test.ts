import { markdown } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { DecorationSet } from '@codemirror/view';
import { describe, expect, it } from 'vitest';
import { buildMarkdownConcealDecorations } from './MarkdownConceal';

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
    extensions: [markdown()],
  });
}

function concealRanges(decorations: DecorationSet, docLength: number): Array<[number, number]> {
  const ranges: Array<[number, number]> = [];
  decorations.between(0, docLength, (from, to) => {
    if (to > from) ranges.push([from, to]); // skip zero-length line decorations
  });
  return ranges;
}

describe('MarkdownConceal per-construct reveal', () => {
  it('reveals only the construct the caret touches, not the whole line', () => {
    const doc = '**one** middle **two**';
    const state = stateWithSelection(doc, doc.indexOf('one'));
    const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true }), doc.length);

    // First bold span (construct containing the caret): marks revealed.
    const firstSpanEnd = doc.indexOf('middle');
    expect(ranges.filter(([from]) => from < firstSpanEnd)).toEqual([]);

    // Second bold span on the SAME line stays concealed.
    const secondSpanStart = doc.indexOf('**two**');
    expect(ranges.filter(([from]) => from >= secondSpanStart).length).toBe(2);
  });

  it('conceals everything while the mouse is down, even at the caret', () => {
    const doc = '**one** middle **two**';
    const state = stateWithSelection(doc, doc.indexOf('one'));
    const ranges = concealRanges(
      buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true, revealForSelection: false }),
      doc.length
    );
    expect(ranges.length).toBe(4); // both spans' opening+closing marks concealed
  });

  it('reveals heading marks only while the selection touches the heading', () => {
    const doc = '# Title\n\nBody text';
    const onHeading = stateWithSelection(doc, 2);
    const offHeading = stateWithSelection(doc, doc.indexOf('Body'));

    const revealed = concealRanges(buildMarkdownConcealDecorations(viewFor(onHeading), { ensureInitialParse: true }), doc.length);
    expect(revealed).toEqual([]);

    const concealed = concealRanges(buildMarkdownConcealDecorations(viewFor(offHeading), { ensureInitialParse: true }), doc.length);
    expect(concealed.length).toBe(1); // '# ' concealed again
  });

  it('renders incomplete links fully raw (no conceal decorations)', () => {
    for (const doc of ['See [Safari]() here', 'See []() here', 'See [](https://x.com) here']) {
      const state = stateWithSelection(doc, 0);
      const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true }), doc.length);
      expect(ranges).toEqual([]);
    }
  });

  it('leaves chip-eligible http links to the chip layer but conceals complete ticker-pdf links', () => {
    const doc = '[Safari](https://apple.com) and [Book p.3](ticker-pdf://abc?page=3)';
    const state = stateWithSelection(doc, doc.length);
    const ranges = concealRanges(buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true }), doc.length);

    const httpLinkEnd = doc.indexOf(')') + 1;
    expect(ranges.filter(([from]) => from < httpLinkEnd)).toEqual([]);

    const tickerStart = doc.indexOf('[Book');
    expect(ranges.filter(([from]) => from >= tickerStart).length).toBeGreaterThan(0);
  });
});
