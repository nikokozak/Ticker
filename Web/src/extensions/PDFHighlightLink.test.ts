import { describe, expect, it } from 'vitest';
import { parseTickerPDFURL } from './PDFHighlightLink';

describe('parseTickerPDFURL', () => {
  it('extracts source, highlight, and page from ticker pdf links', () => {
    expect(parseTickerPDFURL('ticker-pdf://source-1?highlight=abc%20123&page=7')).toEqual({
      sourceId: 'source-1',
      highlightId: 'abc 123',
      page: 7,
    });
  });

  it('keeps highlight and page optional', () => {
    expect(parseTickerPDFURL('ticker-pdf://source-2')).toEqual({
      sourceId: 'source-2',
      highlightId: undefined,
      page: undefined,
    });
  });

  it('rejects other URL schemes and invalid source ids', () => {
    expect(parseTickerPDFURL('https://example.com/file.pdf')).toBeNull();
    expect(parseTickerPDFURL('ticker-pdf://')).toBeNull();
  });
});
