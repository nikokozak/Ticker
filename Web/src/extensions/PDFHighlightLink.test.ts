import { describe, expect, it } from 'vitest';
import { findTickerPDFHighlightLink, parseTickerPDFURL } from './PDFHighlightLink';

describe('parseTickerPDFURL', () => {
  it('extracts source, highlight, and page from ticker pdf links', () => {
    expect(parseTickerPDFURL('ticker-pdf://source-1?highlight=abc%20123&page=7')).toEqual({
      sourceId: 'source-1',
      highlightId: 'abc 123',
      page: 7,
      chunkId: undefined,
      quote: undefined,
      rawURL: 'ticker-pdf://source-1?highlight=abc%20123&page=7',
    });
  });

  it('keeps highlight and page optional', () => {
    expect(parseTickerPDFURL('ticker-pdf://source-2')).toEqual({
      sourceId: 'source-2',
      highlightId: undefined,
      page: undefined,
      chunkId: undefined,
      quote: undefined,
      rawURL: 'ticker-pdf://source-2',
    });
  });

  it('extracts citation chunk destinations', () => {
    expect(parseTickerPDFURL('ticker-pdf://source-3?page=12&chunk=chunk-123&q=quoted%20span')).toEqual({
      sourceId: 'source-3',
      highlightId: undefined,
      page: 12,
      chunkId: 'chunk-123',
      quote: 'quoted span',
      rawURL: 'ticker-pdf://source-3?page=12&chunk=chunk-123&q=quoted%20span',
    });
  });

  it('treats a bare UUID host as a legacy highlight id', () => {
    const id = '11111111-2222-3333-4444-555555555555';
    expect(parseTickerPDFURL(`ticker-pdf://${id}`)).toEqual({
      highlightId: id,
      page: undefined,
      chunkId: undefined,
      quote: undefined,
      rawURL: `ticker-pdf://${id}`,
    });
  });

  it('rejects other URL schemes and invalid source ids', () => {
    expect(parseTickerPDFURL('https://example.com/file.pdf')).toBeNull();
    expect(parseTickerPDFURL('ticker-pdf://')).toBeNull();
  });
});

describe('findTickerPDFHighlightLink', () => {
  const sourceId = '11111111-1111-1111-1111-111111111111';
  const highlightId = '22222222-2222-2222-2222-222222222222';

  it('finds a current highlight link anywhere in the full markdown string', () => {
    const markdown = `${'Earlier text. '.repeat(2_000)}[Manual \\[draft\\] p.7](ticker-pdf://${sourceId}?highlight=${highlightId}&page=7)`;
    const match = findTickerPDFHighlightLink(markdown, highlightId, sourceId);
    const labelStart = markdown.indexOf('Manual');

    expect(match).toEqual({
      from: labelStart,
      to: labelStart + 'Manual \\[draft\\] p.7'.length,
      rawURL: `ticker-pdf://${sourceId}?highlight=${highlightId}&page=7`,
    });
  });

  it('finds the legacy bare-highlight URL form', () => {
    const markdown = `Before [Legacy anchor](ticker-pdf://${highlightId}) after`;
    const match = findTickerPDFHighlightLink(markdown, highlightId, sourceId);

    expect(match).toEqual({
      from: markdown.indexOf('Legacy anchor'),
      to: markdown.indexOf('Legacy anchor') + 'Legacy anchor'.length,
      rawURL: `ticker-pdf://${highlightId}`,
    });
  });

  it('ignores citation, page-only, and other-source links', () => {
    const markdown = [
      `[Citation](ticker-pdf://${sourceId}?page=7&chunk=chunk-1)`,
      `[Page](ticker-pdf://${sourceId}?page=7)`,
      `[Other](ticker-pdf://33333333-3333-3333-3333-333333333333?highlight=${highlightId}&page=7)`,
    ].join('\n');

    expect(findTickerPDFHighlightLink(markdown, highlightId, sourceId)).toBeNull();
  });
});
