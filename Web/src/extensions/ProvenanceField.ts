import { EditorState, StateEffect, StateField, Transaction, type Text } from '@codemirror/state';
import { invertedEffects } from '@codemirror/commands';
import { fnv1a } from '../utils/fnv1a';

export interface Span {
  spanId: string;
  start: number;
  end: number;
  origin: 'ai' | 'source' | 'capture';
  requestId?: string;
  sourceId?: string;
  meta: Record<string, unknown>;
  textHash: string;
  createdAt: number;
}

export const setSpans = StateEffect.define<Span[]>();
export const addSpans = StateEffect.define<Span[]>();
export const dissolveSpans = StateEffect.define<string[]>();

function docText(doc: Text | string, start: number, end: number): string {
  return typeof doc === 'string' ? doc.slice(start, end) : doc.sliceString(start, end);
}

function docLength(doc: Text | string): number {
  return typeof doc === 'string' ? doc.length : doc.length;
}

function withHash(span: Span, start: number, end: number, doc: Text | string, spanId = span.spanId): Span | null {
  if (start < 0 || end > docLength(doc) || end - start < 3) return null;
  return {
    ...span,
    spanId,
    start,
    end,
    meta: { ...span.meta },
    textHash: fnv1a(docText(doc, start, end)),
  };
}

function insertionChanges(transaction: Transaction) {
  const insertions: Array<{ from: number; length: number }> = [];
  transaction.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    if (fromA === toA && inserted.length > 0) {
      insertions.push({ from: fromA, length: inserted.length });
    }
  });
  return insertions;
}

function mapBoundaryStart(span: Span, transaction: Transaction, insertions: Array<{ from: number; length: number }>): number {
  let start = transaction.changes.mapPos(span.start, -1);
  // CM's assoc pair alone includes edge inserts; trim them so boundary text remains the user's.
  for (const insertion of insertions) {
    if (insertion.from === span.start) start += insertion.length;
  }
  return start;
}

function mapBoundaryEnd(span: Span, transaction: Transaction, insertions: Array<{ from: number; length: number }>): number {
  let end = transaction.changes.mapPos(span.end, 1);
  // CM's assoc pair alone includes edge inserts; trim them so boundary text remains the user's.
  for (const insertion of insertions) {
    if (insertion.from === span.end) end -= insertion.length;
  }
  return end;
}

function mapSpan(span: Span, transaction: Transaction, insertions: Array<{ from: number; length: number }>): Span[] {
  const insideInsertions = insertions
    .filter((insertion) => insertion.from > span.start && insertion.from < span.end)
    .sort((a, b) => a.from - b.from);

  if (insideInsertions.length === 0) {
    const mapped = withHash(
      span,
      mapBoundaryStart(span, transaction, insertions),
      mapBoundaryEnd(span, transaction, insertions),
      transaction.state.doc
    );
    return mapped ? [mapped] : [];
  }

  const pieces: Span[] = [];
  let previousInsertion: { from: number; length: number } | null = null;
  for (const insertion of insideInsertions) {
    const start = previousInsertion
      ? transaction.changes.mapPos(previousInsertion.from, 1)
      : mapBoundaryStart(span, transaction, insertions);
    const end = transaction.changes.mapPos(insertion.from, -1);
    const piece = withHash(span, start, end, transaction.state.doc, crypto.randomUUID());
    if (piece) pieces.push(piece);
    previousInsertion = insertion;
  }

  const lastStart = previousInsertion
    ? transaction.changes.mapPos(previousInsertion.from, 1)
    : mapBoundaryStart(span, transaction, insertions);
  const last = withHash(span, lastStart, mapBoundaryEnd(span, transaction, insertions), transaction.state.doc, crypto.randomUUID());
  if (last) pieces.push(last);
  return pieces;
}

export function normalizeSpans(spans: Span[], doc: Text | string): Span[] {
  const sorted = spans
    .flatMap((span) => {
      const normalized = withHash(span, span.start, span.end, doc);
      return normalized ? [normalized] : [];
    })
    .sort((a, b) => a.start - b.start || a.end - b.end || a.spanId.localeCompare(b.spanId));

  const merged: Span[] = [];
  for (const span of sorted) {
    const previous = merged[merged.length - 1];
    if (previous && previous.end === span.start && previous.requestId === span.requestId && previous.origin === span.origin) {
      const combined = withHash(previous, previous.start, span.end, doc);
      if (combined) merged[merged.length - 1] = combined;
      continue;
    }
    merged.push(span);
  }
  return merged;
}

export const provenanceField: StateField<Span[]> = StateField.define<Span[]>({
  create: () => [],
  update(spans, transaction) {
    let next = transaction.docChanged
      ? spans.flatMap((span) => mapSpan(span, transaction, insertionChanges(transaction)))
      : spans;

    for (const effect of transaction.effects) {
      if (effect.is(setSpans)) {
        next = effect.value;
      } else if (effect.is(addSpans)) {
        next = [...next, ...effect.value];
      } else if (effect.is(dissolveSpans)) {
        const ids = new Set(effect.value);
        next = next.filter((span) => !ids.has(span.spanId));
      }
    }

    return next;
  },
  provide: () => invertedEffects.of((transaction) => {
    const effects: StateEffect<unknown>[] = [];
    for (const effect of transaction.effects) {
      if (effect.is(addSpans)) {
        effects.push(dissolveSpans.of(effect.value.map((span) => span.spanId)));
      } else if (effect.is(dissolveSpans)) {
        const ids = new Set(effect.value);
        const removed = currentSpans(transaction.startState).filter((span) => ids.has(span.spanId));
        if (removed.length > 0) effects.push(addSpans.of(removed));
      }
    }
    return effects;
  }),
});

export function currentSpans(state: EditorState): Span[] {
  return state.field(provenanceField, false) ?? [];
}
