import { EditorState, Transaction, type Extension } from '@codemirror/state';
import { history, undo } from '@codemirror/commands';
import { describe, expect, it } from 'vitest';
import { fnv1a } from '../utils/fnv1a';
import {
  addSpans,
  currentSpans,
  dissolveSpans,
  normalizeSpans,
  provenanceField,
  setSpans,
  type Span,
} from './ProvenanceField';

function spanFor(doc: string, start: number, end: number, extra: Partial<Span> = {}): Span {
  return {
    spanId: extra.spanId ?? crypto.randomUUID(),
    start,
    end,
    origin: extra.origin ?? 'ai',
    requestId: extra.requestId,
    sourceId: extra.sourceId,
    meta: extra.meta ?? {},
    textHash: fnv1a(doc.slice(start, end)),
    createdAt: extra.createdAt ?? 1,
  };
}

function stateWith(doc: string, spans: Span[], extraExtensions: Extension[] = []) {
  let state = EditorState.create({
    doc,
    extensions: [provenanceField, ...extraExtensions],
  });
  state = state.update({ effects: setSpans.of(spans) }).state;
  return state;
}

function expectHashesMatch(state: EditorState) {
  for (const span of currentSpans(state)) {
    const covered = state.doc.sliceString(span.start, span.end);
    expect(span.end).toBeGreaterThan(span.start);
    expect(span.end - span.start).toBeGreaterThanOrEqual(3);
    expect(span.textHash).toBe(fnv1a(covered));
  }
}

describe('ProvenanceField', () => {
  it('splits a span on insertion strictly inside it and recomputes hashes', () => {
    let state = stateWith('Hello world', [spanFor('Hello world', 0, 11, { spanId: 'span-1', requestId: 'r1' })]);

    state = state.update({ changes: { from: 5, insert: ' brave' } }).state;

    const spans = currentSpans(state);
    expect(spans).toHaveLength(2);
    expect(spans.map((span) => state.doc.sliceString(span.start, span.end))).toEqual(['Hello', ' world']);
    expect(spans.every((span) => span.spanId !== 'span-1')).toBe(true);
    expect(spans.map((span) => span.requestId)).toEqual(['r1', 'r1']);
    expectHashesMatch(state);
  });

  it('keeps boundary insertions outside the span', () => {
    let state = stateWith('Hello', [spanFor('Hello', 0, 5, { spanId: 'span-1' })]);

    state = state.update({ changes: { from: 0, insert: 'X' } }).state;
    expect(currentSpans(state).map((span) => state.doc.sliceString(span.start, span.end))).toEqual(['Hello']);

    state = state.update({ changes: { from: state.doc.length, insert: '!' } }).state;
    expect(currentSpans(state).map((span) => state.doc.sliceString(span.start, span.end))).toEqual(['Hello']);
    expectHashesMatch(state);
  });

  it('keeps the existing hash when edits do not touch covered text', () => {
    const original = spanFor('beforeHello', 6, 11, { spanId: 'span-1' });
    let state = stateWith('beforeHello', [{ ...original, textHash: 'already-verified' }]);

    state = state.update({ changes: { from: 0, insert: 'X' } }).state;

    expect(currentSpans(state)[0].textHash).toBe('already-verified');
  });

  it('shrinks a span across deletions', () => {
    let state = stateWith('abcdefghi', [spanFor('abcdefghi', 2, 8, { spanId: 'span-1' })]);

    state = state.update({ changes: { from: 4, to: 6, insert: '' } }).state;

    expect(currentSpans(state).map((span) => state.doc.sliceString(span.start, span.end))).toEqual(['cdgh']);
    expectHashesMatch(state);
  });

  it('drops mapped slivers shorter than three UTF-16 units', () => {
    let state = stateWith('abcdef', [spanFor('abcdef', 2, 6, { spanId: 'span-1' })]);

    state = state.update({ changes: { from: 3, to: 5, insert: '' } }).state;

    expect(currentSpans(state)).toEqual([]);
  });

  it('merges adjacent spans with the same request and origin during normalization', () => {
    const doc = 'abcdef';
    const first = spanFor(doc, 0, 3, { spanId: 'a', requestId: 'r1' });
    const second = spanFor(doc, 3, 6, { spanId: 'b', requestId: 'r1' });

    expect(normalizeSpans([second, first], doc)).toEqual([
      {
        ...first,
        end: 6,
        textHash: fnv1a('abcdef'),
      },
    ]);
  });

  it('does not merge adjacent spans with different source attribution or metadata', () => {
    const doc = 'abcdefghi';
    const first = spanFor(doc, 0, 3, { spanId: 'a', requestId: 'r1', sourceId: 'source-1', meta: { page: 1 } });
    const differentSource = spanFor(doc, 3, 6, { spanId: 'b', requestId: 'r1', sourceId: 'source-2', meta: { page: 1 } });
    const differentMeta = spanFor(doc, 6, 9, { spanId: 'c', requestId: 'r1', sourceId: 'source-2', meta: { page: 2 } });

    expect(normalizeSpans([first, differentSource, differentMeta], doc)).toHaveLength(3);
  });

  it('restores dissolved spans through undo', () => {
    const doc = 'Hello world';
    const span = spanFor(doc, 0, 5, { spanId: 'span-1' });
    let state = stateWith(doc, [span], [history()]);
    const dispatch = (transaction: Transaction) => {
      state = transaction.state;
    };

    state = state.update({
      effects: dissolveSpans.of(['span-1']),
      annotations: Transaction.addToHistory.of(true),
    }).state;
    expect(currentSpans(state)).toEqual([]);

    expect(undo({ state, dispatch })).toBe(true);
    expect(currentSpans(state)).toEqual([span]);
  });

  it('removes added spans through undo', () => {
    const doc = 'Hello world';
    const span = spanFor(doc, 0, 5, { spanId: 'span-1' });
    let state = stateWith(doc, [], [history()]);
    const dispatch = (transaction: Transaction) => {
      state = transaction.state;
    };

    state = state.update({
      effects: addSpans.of([span]),
      annotations: Transaction.addToHistory.of(true),
    }).state;
    expect(currentSpans(state)).toEqual([span]);

    expect(undo({ state, dispatch })).toBe(true);
    expect(currentSpans(state)).toEqual([]);
  });

  it('keeps hashes valid through random edits', () => {
    let seed = 1;
    const rand = () => {
      seed = (seed * 48271) % 0x7fffffff;
      return seed / 0x7fffffff;
    };

    const doc = 'aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeee';
    const spans = [0, 10, 20, 30, 40].map((start, index) => (
      spanFor(doc, start, start + 10, { spanId: `span-${index}`, requestId: `r${index}` })
    ));
    let state = stateWith(doc, spans);
    const alphabet = 'xyz012';

    for (let i = 0; i < 200; i += 1) {
      const length = state.doc.length;
      if (length === 0 || rand() < 0.55) {
        const from = Math.floor(rand() * (length + 1));
        const insert = alphabet[Math.floor(rand() * alphabet.length)];
        state = state.update({ changes: { from, insert } }).state;
      } else {
        const from = Math.floor(rand() * length);
        const to = Math.min(length, from + 1 + Math.floor(rand() * 4));
        state = state.update({ changes: { from, to, insert: '' } }).state;
      }
      expectHashesMatch(state);
    }
  });
});
