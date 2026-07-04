import { describe, expect, it } from 'vitest';
import { findImageTokens } from './MarkdownImageWidget';

describe('findImageTokens', () => {
  it('reports token positions across adjacent text and multiple images', () => {
    const first = '![first](ticker-asset://stream/a.png){width=300}';
    const second = '![second](ticker-asset://stream/b.png)';
    const text = `before ${first} between ${second} after`;

    const tokens = findImageTokens(text);

    expect(tokens).toEqual([
      {
        raw: first,
        from: text.indexOf(first),
        to: text.indexOf(first) + first.length,
        alt: 'first',
        url: 'ticker-asset://stream/a.png',
        width: 300,
      },
      {
        raw: second,
        from: text.indexOf(second),
        to: text.indexOf(second) + second.length,
        alt: 'second',
        url: 'ticker-asset://stream/b.png',
        width: null,
      },
    ]);
  });

  it('applies offsets and normalizes ticker asset URLs', () => {
    const token = '![screenshot](ticker-asset://stream/capture 1.png){width=920}';

    expect(findImageTokens(token, 42)).toEqual([
      {
        raw: token,
        from: 42,
        to: 42 + token.length,
        alt: 'screenshot',
        url: 'ticker-asset://stream/capture%201.png',
        width: 920,
      },
    ]);
  });
});
