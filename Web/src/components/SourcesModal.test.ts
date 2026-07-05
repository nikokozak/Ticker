import { describe, expect, it } from 'vitest';
import { formatSourceIndexStatusLine } from './SourcesModal';

describe('formatSourceIndexStatusLine', () => {
  it('formats indexing progress when present', () => {
    expect(formatSourceIndexStatusLine({ status: 'indexing', progress: 0.424 })).toBe('indexing · 42%');
  });

  it('formats indexing without progress quietly', () => {
    expect(formatSourceIndexStatusLine({ status: 'indexing' })).toBe('indexing…');
  });

  it('merges ready status into the page line', () => {
    expect(formatSourceIndexStatusLine({ status: 'ready', pageCount: 3 })).toBe('3 pages · indexed');
  });

  it('adds the private suffix when AI exclusion is enabled', () => {
    expect(formatSourceIndexStatusLine({ status: 'ready', pageCount: 274, aiExcluded: true })).toBe(
      '274 pages · indexed · private'
    );
  });

  it('keeps a zero-page ready source as the plain page line', () => {
    expect(formatSourceIndexStatusLine({ status: 'ready', pageCount: 0 })).toBe('0 pages');
  });

  it('formats honest failure states', () => {
    expect(formatSourceIndexStatusLine({ status: 'failed_no_text' })).toBe(
      'No readable text — this looks like a scanned document'
    );
    expect(formatSourceIndexStatusLine({ status: 'failed' })).toBe('Indexing failed');
  });

  it('formats pending status', () => {
    expect(formatSourceIndexStatusLine({ status: 'pending' })).toBe('waiting to index…');
  });
});
