import { EditorState, Transaction } from '@codemirror/state';
import { history, isolateHistory, undo } from '@codemirror/commands';
import { describe, expect, it } from 'vitest';
import {
  AI_HISTORY_USER_EVENT,
  aiWritingExtension,
  getAiWritingRange,
  setAiWritingRangeEffect,
} from './AIWritingState';

describe('aiWritingExtension', () => {
  it('maps the active AI writing range through document edits', () => {
    let state = EditorState.create({
      doc: 'Hello world',
      extensions: [aiWritingExtension],
    });

    state = state.update({
      effects: setAiWritingRangeEffect.of({ from: 6, to: 11 }),
    }).state;

    state = state.update({
      changes: { from: 0, insert: 'Say: ' },
    }).state;

    expect(getAiWritingRange(state)).toEqual({ from: 11, to: 16 });

    state = state.update({
      changes: { from: 16, insert: '!' },
    }).state;

    expect(getAiWritingRange(state)).toEqual({ from: 11, to: 17 });
  });

  it('clears the active range explicitly', () => {
    let state = EditorState.create({
      doc: 'Draft',
      extensions: [aiWritingExtension],
    });

    state = state.update({
      effects: setAiWritingRangeEffect.of({ from: 0, to: 5 }),
    }).state;
    state = state.update({
      effects: setAiWritingRangeEffect.of(null),
    }).state;

    expect(getAiWritingRange(state)).toBeNull();
  });

  it('keeps streamed partials out of history and records final AI text as one undo step', () => {
    let state = EditorState.create({
      doc: 'Hello world\n\nTail',
      extensions: [history(), aiWritingExtension],
    });
    const dispatch = (transaction: Transaction) => {
      state = transaction.state;
    };

    state = state.update({
      changes: { from: 6, to: 11, insert: '' },
      effects: setAiWritingRangeEffect.of({ from: 6, to: 6 }),
      annotations: Transaction.addToHistory.of(false),
    }).state;
    state = state.update({
      changes: { from: 6, insert: 'AI draft' },
      effects: setAiWritingRangeEffect.of({ from: 6, to: 14 }),
      annotations: Transaction.addToHistory.of(false),
    }).state;
    state = state.update({
      changes: { from: state.doc.length, insert: ' note' },
      annotations: [
        Transaction.addToHistory.of(true),
        Transaction.userEvent.of('input.type'),
      ],
    }).state;

    const range = getAiWritingRange(state);
    expect(range).toEqual({ from: 6, to: 14 });

    state = state.update({
      changes: { from: range!.from, to: range!.to, insert: 'world' },
      annotations: Transaction.addToHistory.of(false),
    }).state;
    state = state.update({
      changes: { from: range!.from, to: range!.from + 'world'.length, insert: 'AI final' },
      effects: setAiWritingRangeEffect.of(null),
      annotations: [
        Transaction.addToHistory.of(true),
        Transaction.userEvent.of(AI_HISTORY_USER_EVENT),
        isolateHistory.of('full'),
      ],
    }).state;

    expect(state.doc.toString()).toBe('Hello AI final\n\nTail note');
    expect(undo({ state, dispatch })).toBe(true);
    expect(state.doc.toString()).toBe('Hello world\n\nTail note');
  });
});
