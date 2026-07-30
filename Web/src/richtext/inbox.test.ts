import { describe, expect, it } from 'vitest';
import { fnv1a } from '../utils/fnv1a';
import { parseMarkdown } from './markdown';
import { reduceAppendInbox, type InboxAppend } from './inbox';

const rawSpan = (fragment: string) => ({
  spanId: crypto.randomUUID(),
  start: 0,
  end: fragment.length,
  origin: 'capture',
  meta: '{}',
  textHash: fnv1a(fragment),
  createdAt: new Date(0).toISOString(),
});

const row = (
  seq: number,
  fragment: string,
  spans: unknown[] = [],
): InboxAppend => ({
  seq,
  appendId: `append-${seq}`,
  fragment,
  rawSpansJSON: JSON.stringify(spans),
  createdAt: new Date(0).toISOString(),
});

describe('the durable append inbox', () => {
  it('returns the canonical document unchanged when there is nothing to reduce', () => {
    const base = parseMarkdown('Base.');

    expect(reduceAppendInbox(base, [], [])).toEqual({
      ok: true,
      doc: base,
      spans: [],
      consumedThrough: null,
    });
  });

  it('reduces rows by sequence without requiring contiguous revisions', () => {
    const base = parseMarkdown('Base.');
    const before = base.toJSON();
    const bold = '**Second.**';

    const reduced = reduceAppendInbox(base, [], [
      row(9, bold, [rawSpan(bold)]),
      row(3, 'First.'),
    ]);

    expect(reduced.ok).toBe(true);
    if (!reduced.ok) return;
    expect(reduced.doc.toJSON()).toMatchObject({
      content: [
        { type: 'paragraph', content: [{ text: 'Base.' }] },
        { type: 'paragraph', content: [{ text: 'First.' }] },
        { type: 'paragraph', content: [{ text: 'Second.' }] },
      ],
    });
    expect(reduced.consumedThrough).toBe(9);
    expect(reduced.spans).toHaveLength(1);
    expect(reduced.doc.textBetween(reduced.spans[0].from, reduced.spans[0].to))
      .toBe('Second.');
    expect(base.toJSON()).toEqual(before);
  });

  it('refuses malformed raw spans without reducing any row', () => {
    const base = parseMarkdown('Base.');
    const reduced = reduceAppendInbox(base, [], [
      row(1, 'First.'),
      { ...row(2, 'Second.'), rawSpansJSON: '{"not":"an array"}' },
    ]);

    expect(reduced).toEqual({ ok: false, reason: 'malformedSpans' });
    expect(base.textContent).toBe('Base.');
  });

  it('refuses one unplaceable span instead of returning a partial document', () => {
    const base = parseMarkdown('Base.');
    const fragment = 'Claimed.';
    const reduced = reduceAppendInbox(base, [], [
      row(1, 'First.'),
      row(2, fragment, [{ ...rawSpan(fragment), textHash: 'wrong' }]),
    ]);

    expect(reduced).toEqual({ ok: false, reason: 'spanUnplaceable' });
    expect(base.textContent).toBe('Base.');
  });

  it('refuses an empty fragment instead of consuming a row that added nothing', () => {
    const reduced = reduceAppendInbox(parseMarkdown('Base.'), [], [
      row(1, 'First.'),
      row(2, ' \n '),
    ]);

    expect(reduced).toEqual({ ok: false, reason: 'emptyFragment' });
  });

  it('refuses a duplicate span id instead of overwriting its history', () => {
    const fragment = 'Captured.';
    const span = rawSpan(fragment);
    const existing = {
      spanId: span.spanId,
      from: 1,
      to: 5,
      origin: 'capture',
      meta: {},
      textHash: fnv1a('Base'),
      createdAt: 0,
    } as const;

    expect(reduceAppendInbox(parseMarkdown('Base.'), [existing], [
      row(1, fragment, [span]),
    ])).toEqual({ ok: false, reason: 'duplicateSpan' });
    expect(reduceAppendInbox(parseMarkdown('Base.'), [], [
      row(1, fragment, [span]),
      row(2, fragment, [span]),
    ])).toEqual({ ok: false, reason: 'duplicateSpan' });
  });
});
