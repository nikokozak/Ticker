import { markdown } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { DecorationSet } from '@codemirror/view';
import { describe, expect, it } from 'vitest';
import { buildMarkdownConcealDecorations, nextMarkdownConcealDecorations } from './MarkdownConceal';

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

describe('MarkdownConceal drag stability', () => {
  it('freezes reveal decorations while the mouse is down and recomputes on mouseup', () => {
    const doc = '**one**\n**two**';
    const firstState = stateWithSelection(doc, doc.indexOf('one'));
    const secondSelection = doc.indexOf('two');
    const firstDecorations = buildMarkdownConcealDecorations(viewFor(firstState), true);
    const selectionTransaction = firstState.update({ selection: { anchor: secondSelection } });
    const secondView = viewFor(selectionTransaction.state);
    const expectedAfterMouseup = buildMarkdownConcealDecorations(secondView);

    const frozen = nextMarkdownConcealDecorations(firstDecorations, secondView, selectionTransaction.changes, {
      docChanged: selectionTransaction.docChanged,
      viewportChanged: false,
      selectionSet: true,
      rawLinksChanged: false,
      wasMouseDown: true,
      isMouseDown: true,
    });
    expect(rangesFor(frozen, doc.length)).toEqual(rangesFor(firstDecorations, doc.length));

    const recomputed = nextMarkdownConcealDecorations(frozen, secondView, selectionTransaction.changes, {
      docChanged: false,
      viewportChanged: false,
      selectionSet: false,
      rawLinksChanged: false,
      wasMouseDown: true,
      isMouseDown: false,
    });
    expect(rangesFor(recomputed, doc.length)).toEqual(rangesFor(expectedAfterMouseup, doc.length));
    expect(rangesFor(recomputed, doc.length)).not.toEqual(rangesFor(firstDecorations, doc.length));
  });
});
