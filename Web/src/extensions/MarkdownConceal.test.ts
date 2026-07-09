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

function rangesFor(decorations: DecorationSet, docLength: number): string[] {
  const ranges: string[] = [];
  decorations.between(0, docLength, (from, to) => {
    ranges.push(`${from}-${to}`);
  });
  return ranges;
}

describe('MarkdownConceal reveal policy', () => {
  it('reveals marks on the caret line when the mouse is up', () => {
    const doc = '**one**\n**two**';
    const state = stateWithSelection(doc, doc.indexOf('one'));
    const revealed = buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true });
    const lineOneRanges = rangesFor(revealed, doc.length).filter((r) => Number(r.split('-')[0]) < 8);
    expect(lineOneRanges).toEqual([]); // caret line: marks revealed (no conceal decorations)
  });

  it('conceals everything while the mouse is down, even selected lines', () => {
    const doc = '**one**\n**two**';
    const state = stateWithSelection(doc, doc.indexOf('one'));
    const concealed = buildMarkdownConcealDecorations(viewFor(state), {
      ensureInitialParse: true,
      revealForSelection: false,
    });
    // Both lines keep their ** mark conceal decorations.
    expect(rangesFor(concealed, doc.length).length).toBeGreaterThanOrEqual(4);
  });

  it('is a pure build over the current view (no frozen-set staleness)', () => {
    const doc = '# Head\n\n**bold** text';
    const state = stateWithSelection(doc, doc.length);
    const a = buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true });
    const b = buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true });
    expect(rangesFor(a, doc.length)).toEqual(rangesFor(b, doc.length));
  });

  it('leaves chip-eligible http links to the chip layer but still conceals ticker-pdf links', () => {
    const doc = '[Safari](https://apple.com) and [Book p.3](ticker-pdf://abc?page=3)';
    const state = stateWithSelection(doc, doc.length);
    const decorations = buildMarkdownConcealDecorations(viewFor(state), { ensureInitialParse: true });
    const ranges = rangesFor(decorations, doc.length).map((r) => r.split('-').map(Number));

    const httpLinkEnd = doc.indexOf(')') + 1;
    const httpOverlaps = ranges.filter(([from, to]) => from < httpLinkEnd && to > 0);
    expect(httpOverlaps).toEqual([]); // chip layer owns the http link

    const tickerStart = doc.indexOf('[Book');
    const tickerOverlaps = ranges.filter(([from]) => from >= tickerStart);
    expect(tickerOverlaps.length).toBeGreaterThan(0); // ticker-pdf still concealed here
  });
});
