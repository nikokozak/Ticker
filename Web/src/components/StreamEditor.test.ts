import { EditorState, Transaction } from '@codemirror/state';
import { history, undo } from '@codemirror/commands';
import { describe, expect, it } from 'vitest';
import { addSpans, currentSpans, provenanceField } from '../extensions/ProvenanceField';
import { fnv1a } from '../utils/fnv1a';
import { buildDocumentAIProvenanceSpan, documentAIErrorRecovery, nextSourceScope } from './StreamEditor';

describe('nextSourceScope', () => {
  it('cycles auto to all to none to auto', () => {
    expect(nextSourceScope('auto')).toBe('all');
    expect(nextSourceScope('all')).toBe('none');
    expect(nextSourceScope('none')).toBe('auto');
  });
});

describe('documentAIErrorRecovery', () => {
  it('restores cancelled output silently', () => {
    expect(documentAIErrorRecovery('original text', 'cancelled')).toEqual({
      restoreText: 'original text',
      silent: true,
    });
  });

  it('restores other errors with visible feedback', () => {
    expect(documentAIErrorRecovery('original text', 'rate_limited')).toEqual({
      restoreText: 'original text',
      silent: false,
    });
  });
});

describe('buildDocumentAIProvenanceSpan', () => {
  it('covers exactly the inserted text with post-swap metadata', () => {
    const inserted = 'Developed [source](ticker-pdf://source)';
    const span = buildDocumentAIProvenanceSpan({
      requestId: 'request-1',
      start: 7,
      text: inserted,
      verb: 'develop',
      model: 'provider/model',
      parentRequestId: 'parent-1',
      spanId: 'span-1',
      createdAt: 123,
    });

    expect(span).toEqual({
      spanId: 'span-1',
      start: 7,
      end: 7 + inserted.length,
      origin: 'ai',
      requestId: 'request-1',
      meta: { model: 'provider/model', verb: 'develop', parentRequestId: 'parent-1' },
      textHash: fnv1a(inserted),
      createdAt: 123,
    });
  });

  it('rides the same undo entry as inserted AI text', () => {
    let state = EditorState.create({
      doc: 'Original',
      extensions: [provenanceField, history()],
    });
    const dispatch = (transaction: Transaction) => {
      state = transaction.state;
    };
    const inserted = 'Better answer';
    const span = buildDocumentAIProvenanceSpan({
      requestId: 'request-2',
      start: 0,
      text: inserted,
      verb: 'develop',
      model: 'provider/model',
      spanId: 'span-2',
      createdAt: 456,
    });

    state = state.update({
      changes: { from: 0, to: state.doc.length, insert: inserted },
      effects: addSpans.of([span]),
      annotations: Transaction.addToHistory.of(true),
    }).state;
    expect(state.doc.toString()).toBe(inserted);
    expect(currentSpans(state)).toEqual([span]);

    expect(undo({ state, dispatch })).toBe(true);
    expect(state.doc.toString()).toBe('Original');
    expect(currentSpans(state)).toEqual([]);
  });
});
