import { describe, expect, it } from 'vitest';
import { EditorSelection, EditorState } from '@codemirror/state';
import { toggleInlineMark } from './inlineMarks';

function toggle(doc: string, from: number, to: number, marker: string) {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.range(from, to),
  });
  const edit = toggleInlineMark(state, state.selection.main, marker);
  expect(edit).not.toBeNull();
  const next = state.update({
    changes: edit!.changes,
    selection: edit!.newSelection,
  }).state;
  const selection = next.selection.main;
  return {
    doc: next.doc.toString(),
    selected: next.sliceDoc(selection.from, selection.to),
  };
}

describe('toggleInlineMark', () => {
  it('wraps the selected text', () => {
    expect(toggle('Hello world', 6, 11, '**')).toEqual({
      doc: 'Hello **world**',
      selected: 'world',
    });
  });

  it('unwraps a selection that exactly includes the markers', () => {
    expect(toggle('**world**', 0, 9, '**')).toEqual({
      doc: 'world',
      selected: 'world',
    });
  });

  it('unwraps markers just outside the selection', () => {
    expect(toggle('**world**', 2, 7, '**')).toEqual({
      doc: 'world',
      selected: 'world',
    });
  });

  it('wraps multi-word selections', () => {
    expect(toggle('one two three', 4, 13, '*')).toEqual({
      doc: 'one *two three*',
      selected: 'two three',
    });
  });

  it('wraps when only one side touches an existing bold marker', () => {
    expect(toggle('**world', 2, 7, '**')).toEqual({
      doc: '****world**',
      selected: 'world',
    });
  });

  it('wraps italic inside an existing bold selection', () => {
    expect(toggle('**world**', 2, 7, '*')).toEqual({
      doc: '***world***',
      selected: 'world',
    });
  });
});
