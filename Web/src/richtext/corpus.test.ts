import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseMarkdown, serializeMarkdown } from './markdown';

/**
 * The synthetic suites cover shapes I could think of. This one covers the shapes
 * the app actually produced — real streams, most of them AI-written, with the
 * citation links, asset images and pasted fragments that only real use creates.
 *
 * Markdown is an edge format now, but importing an existing export and exporting
 * it again must still preserve the document it represents.
 *
 * Skips when the corpus is absent, so CI stays green without it. Regenerate with
 * the stream export and point TICKER_CORPUS at the directory.
 */

const CORPUS = process.env.TICKER_CORPUS ?? join(process.env.HOME ?? '', 'Desktop/ticker-streams-export');
const files = existsSync(CORPUS) ? readdirSync(CORPUS).filter((name) => name.endsWith('.md')) : [];

describe.skipIf(files.length === 0)('real streams survive a load/save cycle', () => {
  it('found a corpus to check', () => expect(files.length).toBeGreaterThan(0));

  for (const name of files) {
    it(name, () => {
      const source = readFileSync(join(CORPUS, name), 'utf8');
      const doc = parseMarkdown(source);
      const once = serializeMarkdown(doc);

      // Loading then saving must not rewrite the document...
      expect(serializeMarkdown(parseMarkdown(once))).toBe(once);
      // ...and must not change what it MEANS, which byte equality alone would miss.
      expect(parseMarkdown(once).eq(doc)).toBe(true);
    });
  }
});
