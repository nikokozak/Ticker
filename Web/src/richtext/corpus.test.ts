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

/**
 * The shape parsing can never produce on its own.
 *
 * Everything above starts from stored markdown, so it only ever sees documents a
 * parse can build. Appending builds something else: two blocks side by side that
 * were never written next to each other. That is not a corner case — appending is
 * how the quick panel and the AI write, and it is where adjacent same-kind lists
 * silently merged into one, shifting every position after them.
 *
 * Measured on the real corpus, before that was fixed: a bullet-list fragment
 * appended to 23 real streams corrupted 2 of them.
 */
describe.skipIf(files.length === 0)('a fragment appended to a real stream survives the save', () => {
  // What an AI reply or a quick-panel capture actually starts with.
  const FRAGMENTS: Array<[string, string]> = [
    ['a bullet list', '* first option\n* second option'],
    ['a numbered list', '1. step one\n2. step two'],
    ['a paragraph', 'A plain answer.'],
    ['a heading', '## Answer\n\nBody text.'],
  ];

  for (const [label, fragment] of FRAGMENTS) {
    it(label, () => {
      const parsed = parseMarkdown(fragment);
      const broken = files.filter((name) => {
        const base = parseMarkdown(readFileSync(join(CORPUS, name), 'utf8'));
        // Exactly what editor.appendMarkdown does: whole blocks at the very end.
        const appended = base.copy(base.content.append(parsed.content));
        return !parseMarkdown(serializeMarkdown(appended)).eq(appended);
      });
      expect(broken, `${broken.length} of ${files.length} real streams did not survive`).toEqual([]);
    });
  }
});
