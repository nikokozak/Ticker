import { describe, expect, it } from 'vitest';
import { markdownPreviewLine, plainTextFromMarkdown } from './markdownPreview';

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

  it('strips inline HTML and markdown from previews and result labels', () => {
    expect(markdownPreviewLine('# Heading\n\n<u>Components</u> with **bold** and [docs](https://example.com)'))
      .toBe('Components with bold and docs');
    expect(plainTextFromMarkdown('<u>Components</u> **guide**')).toBe('Components guide');
  });
});
