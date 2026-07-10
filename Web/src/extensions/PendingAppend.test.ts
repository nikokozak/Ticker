import { describe, expect, it } from 'vitest';
import { EditorState } from '@codemirror/state';
import { pendingAppendField, pendingAppendIsShown, setPendingAppend } from './PendingAppend';

function stateWithDoc(doc: string): EditorState {
  return EditorState.create({ doc, extensions: [pendingAppendField] });
}

describe('PendingAppend', () => {
  it('shows the indicator at doc end and clears it', () => {
    let state = stateWithDoc('hello');
    expect(pendingAppendIsShown(state)).toBe(false);

    state = state.update({ effects: setPendingAppend.of(true) }).state;
    expect(pendingAppendIsShown(state)).toBe(true);

    let position = -1;
    state.field(pendingAppendField).between(0, state.doc.length, (from) => {
      position = from;
    });
    expect(position).toBe(state.doc.length);

    state = state.update({ effects: setPendingAppend.of(false) }).state;
    expect(pendingAppendIsShown(state)).toBe(false);
  });

  it('re-pins the indicator to the doc end when the document changes', () => {
    let state = stateWithDoc('hello');
    state = state.update({ effects: setPendingAppend.of(true) }).state;
    state = state.update({ changes: { from: state.doc.length, insert: ' world' } }).state;

    let position = -1;
    state.field(pendingAppendField).between(0, state.doc.length, (from) => {
      position = from;
    });
    expect(position).toBe(state.doc.length);
  });
});
