import { describe, expect, it } from 'vitest';
import { fnv1a } from '../utils/fnv1a';
import type { Span } from './ProvenanceField';
import { buildProvenanceDecorationRanges, canRedevelopSpan } from './ProvenanceXray';

function span(start: number, end: number, origin: Span['origin'] = 'ai'): Span {
  return {
    spanId: `${origin}-${start}-${end}`,
    start,
    end,
    origin,
    meta: {},
    textHash: fnv1a('x'.repeat(end - start)),
    createdAt: 1,
  };
}

describe('ProvenanceXray', () => {
  it('builds mark ranges for provenance spans', () => {
    const ranges = buildProvenanceDecorationRanges(
      [span(0, 5, 'ai'), span(6, 12, 'capture'), span(14, 20, 'source')],
      [{ from: 0, to: 30 }]
    );

    expect(ranges.map(({ from, to, className }) => ({ from, to, className }))).toEqual([
      { from: 0, to: 5, className: 'cm-prov-ai' },
      { from: 6, to: 12, className: 'cm-prov-capture' },
      { from: 14, to: 20, className: 'cm-prov-source' },
    ]);
  });

  it('clips spans to visible ranges', () => {
    const ranges = buildProvenanceDecorationRanges(
      [span(0, 20)],
      [{ from: 4, to: 10 }, { from: 14, to: 18 }]
    );

    expect(ranges.map(({ from, to }) => ({ from, to }))).toEqual([
      { from: 4, to: 10 },
      { from: 14, to: 18 },
    ]);
  });

  it('skips atomic widget ranges', () => {
    const ranges = buildProvenanceDecorationRanges(
      [span(0, 20)],
      [{ from: 0, to: 20 }],
      [{ from: 5, to: 12 }]
    );

    expect(ranges.map(({ from, to }) => ({ from, to }))).toEqual([
      { from: 0, to: 5 },
      { from: 12, to: 20 },
    ]);
  });

  it('gates re-develop to idle AI spans with at least three words', () => {
    expect(canRedevelopSpan(span(0, 30, 'ai'), 'one two three', false)).toBe(true);
    expect(canRedevelopSpan(span(0, 30, 'ai'), 'one two', false)).toBe(false);
    expect(canRedevelopSpan(span(0, 30, 'capture'), 'one two three', false)).toBe(false);
    expect(canRedevelopSpan(span(0, 30, 'ai'), 'one two three', true)).toBe(false);
  });
});
