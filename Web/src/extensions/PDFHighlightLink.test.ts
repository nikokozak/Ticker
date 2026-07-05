import { describe, expect, it } from 'vitest';
import { parseTickerPDFURL } from './PDFHighlightLink';

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
