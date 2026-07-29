// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { fnv1a } from '../utils/fnv1a';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';
import { provenanceSpans, provenanceText } from './provenance';
import { DocumentSession, type SessionTransport } from './session';
import { parseRawSpans, placeFragmentSpan, planReplay, type PendingAppend, type RawFragmentSpan } from './pendingAppends';

/**
 * Every step of the replay is a proof. These check that each one actually refuses
 * what it cannot prove, because a half-converted span points at the wrong text and
 * claims the AI wrote something it did not.
 */

const rawSpan = (fragment: string, end = fragment.length, overrides: Partial<RawFragmentSpan> = {}): RawFragmentSpan => ({
  spanId: 'raw-1',
  start: 0,
  end,
  origin: 'ai',
  requestId: 'request-1',
  meta: '{}',
  textHash: fnv1a(fragment.slice(0, end)),
  createdAt: new Date(0).toISOString(),
  ...overrides,
});

const row = (revision: number, fragment: string, spans: RawFragmentSpan[] = [], separator = '\n\n'): PendingAppend => ({
  revision, separator, fragment, rawSpans: spans,
});

describe('peeling the fragments off the stored document', () => {
  it('recovers the base and the fragments in order', () => {
    const plan = planReplay('base\n\none\n\ntwo', 5, [row(4, 'one'), row(5, 'two')]);
    expect(plan).toEqual({
      ok: true,
      baseMarkdown: 'base',
      appends: [{ fragment: 'one', spans: [] }, { fragment: 'two', spans: [] }],
    });
  });

  it('handles the first append into an empty document, which has no separator', () => {
    const plan = planReplay('only', 1, [row(1, 'only', [], '')]);
    expect(plan).toEqual({ ok: true, baseMarkdown: '', appends: [{ fragment: 'only', spans: [] }] });
  });

  it('refuses a gap in the revisions', () => {
    // A missing row means an append nobody recorded, so the suffixes cannot be
    // trusted to be what is actually on the end of the document.
    expect(planReplay('base\n\none\n\ntwo', 6, [row(4, 'one'), row(6, 'two')]))
      .toEqual({ ok: false, reason: 'revisionGap' });
  });

  it('refuses rows that do not reach the document revision', () => {
    expect(planReplay('base\n\none', 9, [row(4, 'one')]))
      .toEqual({ ok: false, reason: 'revisionMismatch' });
  });

  it('refuses when the document does not actually end with the fragment', () => {
    expect(planReplay('base\n\nsomething else', 4, [row(4, 'one')]))
      .toEqual({ ok: false, reason: 'suffixMismatch' });
  });

  it('does nothing when there is nothing pending', () => {
    expect(planReplay('base', 3, [])).toEqual({ ok: true, baseMarkdown: 'base', appends: [] });
  });
});

describe('decoding what the store carries', () => {
  it('reads a well-formed row', () => {
    expect(parseRawSpans(JSON.stringify([rawSpan('hello')]))).toHaveLength(1);
  });
  it('survives malformed JSON rather than throwing', () => {
    expect(parseRawSpans('not json')).toEqual([]);
    expect(parseRawSpans('')).toEqual([]);
    expect(parseRawSpans('{"not":"an array"}')).toEqual([]);
  });
  it('drops rows missing what a span needs', () => {
    expect(parseRawSpans(JSON.stringify([{ spanId: 'x' }, { start: 0, end: 1 }]))).toEqual([]);
  });
});

describe('placing one fragment span', () => {
  const place = (fragment: string, raw: RawFragmentSpan, insertedAt = 0) => {
    const doc = parseMarkdown(fragment);
    return placeFragmentSpan(raw, fragment, insertedAt, doc);
  };

  it('covers exactly the text the offsets described', () => {
    const fragment = 'The AI wrote this.';
    const doc = parseMarkdown(fragment);
    const span = placeFragmentSpan(rawSpan(fragment), fragment, 0, doc);
    expect(span).not.toBe(null);
    expect(doc.textBetween(span!.from, span!.to)).toBe('The AI wrote this.');
  });

  it('keeps the identity the store recorded', () => {
    const fragment = 'The AI wrote this.';
    const span = place(fragment, rawSpan(fragment));
    expect(span?.spanId).toBe('raw-1');
    expect(span?.requestId).toBe('request-1');
    expect(span?.origin).toBe('ai');
  });

  it('rehashes over the document text, not the markdown', () => {
    // The markdown and the text differ the moment there is any formatting.
    const fragment = 'The **AI** wrote this.';
    const doc = parseMarkdown(fragment);
    const span = placeFragmentSpan(rawSpan(fragment), fragment, 0, doc);
    expect(span?.textHash).toBe(fnv1a('The AI wrote this.'));
  });

  it('refuses a span that does not start at the fragment start', () => {
    const fragment = 'The AI wrote this.';
    expect(place(fragment, rawSpan(fragment, fragment.length, { start: 4 }))).toBe(null);
  });

  it('refuses a span whose hash does not match its own fragment', () => {
    const fragment = 'The AI wrote this.';
    expect(place(fragment, rawSpan(fragment, fragment.length, { textHash: 'drifted' }))).toBe(null);
  });

  it('refuses offsets that run past the fragment', () => {
    const fragment = 'short';
    expect(place(fragment, rawSpan(fragment, 99))).toBe(null);
  });

  it('refuses a span that ends halfway through a block', () => {
    // There is no document position for half a paragraph, so a span that does not
    // cover whole blocks from the start cannot be placed without guessing.
    const fragment = 'First paragraph.\n\nSecond paragraph.';
    const half = 'First paragraph.\n\nSecond';
    expect(place(fragment, rawSpan(fragment, half.length))).toBe(null);
  });

  it('accepts a span covering whole blocks from the start', () => {
    const fragment = '## A heading\n\nAnd a paragraph.\n\nAnd another.';
    const prefix = '## A heading\n\nAnd a paragraph.';
    const doc = parseMarkdown(fragment);
    const span = placeFragmentSpan(rawSpan(fragment, prefix.length), fragment, 0, doc);
    expect(span).not.toBe(null);
    expect(doc.textBetween(span!.from, span!.to, '\n')).toBe('A heading\nAnd a paragraph.');
  });

  it('offsets by where the fragment actually landed', () => {
    const fragment = 'The AI wrote this.';
    const atZero = place(fragment, rawSpan(fragment), 0)!;
    // A document big enough to hold it further along, since the placement is
    // bounds-checked against the document it is going into.
    const whole = parseMarkdown(`padding paragraph\n\n${fragment}`);
    const insertedAt = whole.content.size - (parseMarkdown(fragment).content.size);
    const later = placeFragmentSpan(rawSpan(fragment), fragment, insertedAt, whole)!;
    expect(later.from - atZero.from).toBe(insertedAt);
    expect(whole.textBetween(later.from, later.to)).toBe('The AI wrote this.');
  });

  it('refuses a placement that would fall outside the document', () => {
    const fragment = 'The AI wrote this.';
    expect(place(fragment, rawSpan(fragment), 10_000)).toBe(null);
  });
});

describe('a session opening a stream with pending appends', () => {
  let editor: RichTextEditor | null = null;
  let session: DocumentSession | null = null;

  afterEach(() => {
    session?.destroy();
    editor?.destroy();
    editor = null;
    session = null;
    document.body.innerHTML = '';
  });

  function open(markdown: string, revision: number, pending: PendingAppend[]) {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const saves: Array<{ markdown: string; spans: unknown[]; resolvedPendingThrough?: number }> = [];
    const errors: string[] = [];
    const transport: SessionTransport = {
      save: async (request) => {
        saves.push({
          markdown: request.markdown,
          spans: request.spans,
          resolvedPendingThrough: request.resolvedPendingThrough,
        });
        return { revision: revision + 1 };
      },
      reload: () => {},
      onError: (message) => errors.push(message),
    };
    editor = createRichTextEditor({ parent, markdown, onChange: () => session?.documentChanged() });
    session = new DocumentSession({
      streamId: 'stream-1', editor, transport, revision, autosaveDelay: 5, pendingAppends: pending,
    });
    return { ed: editor, session, saves, errors };
  }

  it('places the provenance and leaves the text exactly as it was', async () => {
    const fragment = 'The AI appended this.';
    const stored = `existing text\n\n${fragment}`;
    const h = open(stored, 4, [row(4, fragment, [rawSpan(fragment)])]);

    expect(h.ed.getMarkdown()).toBe(stored);
    const [placed] = provenanceSpans(h.ed.view.state);
    expect(placed, 'the append provenance was not converted').toBeDefined();
    expect(provenanceText(h.ed.view.state.doc, placed)).toBe('The AI appended this.');

    // Saved on purpose although the markdown is unchanged: without a save the
    // pending rows are never cleared and this happens again on every open.
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].markdown).toBe(stored);
    expect(h.saves[0].spans).toHaveLength(1);
    // Only a save that says so may clear the rows.
    expect(h.saves[0].resolvedPendingThrough).toBe(4);
  });

  it('places provenance across several appends', () => {
    const one = 'First AI addition.';
    const two = 'Second AI addition.';
    const h = open(`base\n\n${one}\n\n${two}`, 6, [
      row(5, one, [rawSpan(one)]),
      row(6, two, [rawSpan(two, two.length, { spanId: 'raw-2' })]),
    ]);
    const placed = provenanceSpans(h.ed.view.state);
    expect(placed).toHaveLength(2);
    expect(placed.map((span) => provenanceText(h.ed.view.state.doc, span)))
      .toEqual(['First AI addition.', 'Second AI addition.']);
  });

  it('leaves the document untouched when the sequence cannot be proven', () => {
    const stored = 'existing text\n\nsomething the rows do not describe';
    const h = open(stored, 4, [row(4, 'a different fragment', [rawSpan('a different fragment')])]);
    expect(h.ed.getMarkdown()).toBe(stored);
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
    expect(h.errors[0]).toMatch(/text itself is intact/);
  });

  it('keeps the text when only one span cannot be placed', () => {
    const fragment = 'The AI appended this.';
    const stored = `existing text\n\n${fragment}`;
    const h = open(stored, 4, [row(4, fragment, [rawSpan(fragment, fragment.length, { textHash: 'drifted' })])]);
    expect(h.ed.getMarkdown()).toBe(stored);
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
  });

  it('converts ALL of a row or none of it', async () => {
    // A partial conversion is the worst outcome: the save that follows would clear
    // the rows, so a span that could not be placed is gone permanently rather than
    // merely deferred until a version that can place it.
    const fragment = 'First AI addition.\n\nSecond AI addition.';
    const stored = `base\n\n${fragment}`;
    const h = open(stored, 4, [row(4, fragment, [
      rawSpan(fragment, 'First AI addition.'.length),
      rawSpan(fragment, fragment.length, { spanId: 'raw-2', textHash: 'drifted' }),
    ])]);

    expect(provenanceSpans(h.ed.view.state), 'a placeable span was kept from a failed row').toHaveLength(0);
    expect(h.ed.getMarkdown()).toBe(stored);
    await h.session.saveNow();
    // Nothing is saved, so nothing clears the rows.
    expect(h.saves.map((save) => save.resolvedPendingThrough)).not.toContain(4);
  });

  it('never claims rows it did not convert', async () => {
    const h = open('base', 3, []);
    h.ed.view.dispatch(h.ed.view.state.tr.insertText('x', 1));
    await h.session.saveNow();
    expect(h.saves[0].resolvedPendingThrough).toBeUndefined();
  });
});
