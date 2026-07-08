import { describe, expect, it } from 'vitest';
import { buildLinkEditChange, isAllowedExternalURL } from './LinkInteraction';

describe('link interaction helpers', () => {
  it('builds a markdown link replacement change', () => {
    expect(buildLinkEditChange({ from: 4, to: 28 }, 'Example', 'https://example.com')).toEqual({
      from: 4,
      to: 28,
      insert: '[Example](https://example.com)',
    });
  });

  it('escapes edited link labels and trims URL fields', () => {
    expect(buildLinkEditChange({ from: 0, to: 10 }, 'A ] B', ' https://example.com/path ')).toEqual({
      from: 0,
      to: 10,
      insert: '[A \\] B](https://example.com/path)',
    });
  });

  it('rejects empty edited links', () => {
    expect(buildLinkEditChange({ from: 0, to: 10 }, '', 'https://example.com')).toBeNull();
    expect(buildLinkEditChange({ from: 0, to: 10 }, 'Example', '')).toBeNull();
  });

  it('allows only http and https external URLs', () => {
    expect(isAllowedExternalURL('https://example.com/path')).toBe(true);
    expect(isAllowedExternalURL('http://example.com')).toBe(true);
    expect(isAllowedExternalURL('ticker-pdf://source?page=1')).toBe(false);
    expect(isAllowedExternalURL('file:///etc/passwd')).toBe(false);
    expect(isAllowedExternalURL('javascript:alert(1)')).toBe(false);
    expect(isAllowedExternalURL('https:example.com')).toBe(false);
  });
});
