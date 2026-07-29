import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseMarkdown, serializeMarkdown } from './markdown';
import { isNormalized } from './normalize';

/**
 * The synthetic suites cover shapes I could think of. This one covers the shapes
 * the app actually produced — real streams, most of them AI-written, with the
 * citation links, asset images and pasted fragments that only real use creates.
 *
 * Two properties, both about a save/reload never surprising the user:
 *   1. parsing is stable — a document that is loaded and saved is unchanged, so
 *      merely OPENING a stream can never rewrite it;
 *   2. every parsed document is already normalised, so the editor's normalisation
 *      is a no-op on existing content rather than an edit nobody asked for.
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
      // Normalisation is for documents the editor builds, never for stored ones.
      expect(isNormalized(doc)).toBe(true);
    });
  }
});
