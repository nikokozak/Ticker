import { ChangeSet } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import {
  buildPDFAnchorLinkEdit,
  buildPDFQuoteSnippet,
  mapPendingPDFAnchorSelection,
} from './pdfAnchorSelection';

describe('pdf anchor selection helpers', () => {
  it('maps a pending selection through document changes and wraps it', () => {
    const original = 'Alpha selected text Omega';
    const from = original.indexOf('selected');
    const to = from + 'selected text'.length;
    const changes = ChangeSet.of([{ from: 0, insert: 'Intro ' }], original.length);

    const mapped = mapPendingPDFAnchorSelection({ from, to }, changes);
    expect(mapped).toEqual({ from: from + 6, to: to + 6 });

    const updated = 'Intro Alpha selected text Omega';
    const edit = buildPDFAnchorLinkEdit(updated, mapped!, 'ticker-pdf://source?highlight=h1&page=2');

    expect(edit?.markdown).toBe('Intro Alpha [selected text](ticker-pdf://source?highlight=h1&page=2) Omega');
  });

  it('returns null when the mapped selection is gone', () => {
    const text = 'Alpha selected text Omega';
    const from = text.indexOf('selected');
    const to = from + 'selected text'.length;
    const changes = ChangeSet.of([{ from, to, insert: '' }], text.length);

    expect(mapPendingPDFAnchorSelection({ from, to }, changes)).toBeNull();
  });

  it('builds a compact PDF quote with an escaped source link', () => {
    expect(buildPDFQuoteSnippet({
      quote: '  A wrapped\nPDF   quote.  ',
      linkLabel: 'Guide \\ [draft] p.7',
      linkURL: 'ticker-pdf://source?highlight=h1&page=7',
    })).toBe(
      '\n> A wrapped PDF quote. [Guide \\\\ \\[draft\\] p.7](ticker-pdf://source?highlight=h1&page=7)\n'
    );
  });
});
