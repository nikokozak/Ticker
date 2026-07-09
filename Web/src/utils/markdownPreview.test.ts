import { describe, expect, it } from 'vitest';
import { markdownPreviewLine } from './markdownPreview';

describe('markdownPreviewLine', () => {
  it('uses the first useful non-heading line', () => {
    expect(markdownPreviewLine('# Heading\n\n> **Linked** [label](https://example.com)')).toBe('Linked label');
  });

  it('skips standalone images', () => {
    expect(markdownPreviewLine('![alt](asset://image)\n\n- `code` note')).toBe('code note');
  });

  it('strips common markdown marks', () => {
    expect(markdownPreviewLine('*hello* __there__ #tag')).toBe('hello there tag');
  });
});
