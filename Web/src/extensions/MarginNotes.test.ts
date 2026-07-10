import { describe, expect, it } from 'vitest';
import { EditorState } from '@codemirror/state';
import { fnv1a } from '../utils/fnv1a';
import {
  buildPromoteMarginNoteEdit,
  currentMarginNotes,
  marginNotesField,
  normalizeMarginNoteAnchors,
  setMarginNotes,
  stackMarginCards,
  type MarginNote,
} from './MarginNotes';

function note(extra: Partial<MarginNote> = {}): MarginNote {
  return {
    noteId: 'note-1',
    streamId: 'stream-1',
    anchorStart: 0,
    anchorEnd: 5,
    anchorHash: fnv1a('Hello'),
    kind: 'question',
    body: 'What assumption is doing the work here?',
    bodyHash: 'bodyhash',
    requestId: 'request-1',
    status: 'open',
    createdAt: '2026-07-08T00:00:00Z',
    ...extra,
  };
}

describe('MarginNotes', () => {
  it('stacks colliding cards downward with an 8px gap', () => {
    expect(stackMarginCards([
      { noteId: 'a', top: 10, height: 30 },
      { noteId: 'b', top: 25, height: 20 },
      { noteId: 'c', top: 80, height: 10 },
    ])).toEqual([
      { noteId: 'a', top: 10, height: 30, y: 10 },
      { noteId: 'b', top: 25, height: 20, y: 48 },
      { noteId: 'c', top: 80, height: 10, y: 80 },
    ]);
  });

  it('marks anchor hash mismatches as unanchored', () => {
    expect(normalizeMarginNoteAnchors([note()], 'Hello world')[0].status).toBe('open');
    expect(normalizeMarginNoteAnchors([note()], 'Hullo world')[0].status).toBe('unanchored');
  });

  it('preserves field identity for selection-only transactions', () => {
    let state = EditorState.create({ doc: 'Hello world', extensions: [marginNotesField] });
    state = state.update({ effects: setMarginNotes.of([note()]) }).state;
    const notes = currentMarginNotes(state);

    state = state.update({ selection: { anchor: 5 } }).state;

    expect(currentMarginNotes(state)).toBe(notes);
  });

  it('builds promote insertion at paragraph end with an ai span', () => {
    const doc = 'Hello world\nstill same paragraph\n\nNext paragraph';
    const edit = buildPromoteMarginNoteEdit(note({
      anchorEnd: 5,
      body: 'This should be part of the draft.',
    }), doc, { spanId: 'span-1', createdAt: 10 });

    expect(edit).toEqual({
      from: 'Hello world\nstill same paragraph'.length,
      insert: '\n\nThis should be part of the draft.',
      span: {
        spanId: 'span-1',
        start: 'Hello world\nstill same paragraph'.length,
        end: 'Hello world\nstill same paragraph'.length + '\n\nThis should be part of the draft.'.length,
        origin: 'ai',
        requestId: 'request-1',
        meta: { verb: 'readBack', marginNoteId: 'note-1', kind: 'question' },
        textHash: fnv1a('\n\nThis should be part of the draft.'),
        createdAt: 10,
      },
    });
  });
});
