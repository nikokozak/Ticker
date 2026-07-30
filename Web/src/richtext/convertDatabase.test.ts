import { afterEach, describe, expect, it } from 'vitest';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fnv1a } from '../utils/fnv1a';
import { parseMarkdown, serializeMarkdown } from './markdown';
import { tickerSchema } from './schema';
import {
  assertDocumentEqual,
  convertDatabase,
  decodeRawSpansStrict,
} from './convertDatabase';

interface FixtureSpan {
  spanId: string;
  start: number;
  end: number;
  origin: string;
  requestId?: string;
  sourceId?: string;
  meta: string;
  textHash: string;
  createdAt: string;
}

interface FixtureDocument {
  id: string;
  markdown: string;
  revision?: number;
  spans?: FixtureSpan[];
  pending?: Array<{
    revision: number;
    separator: string;
    fragment: string;
    rawSpans: unknown;
  }>;
}

const tempDirectories: string[] = [];

afterEach(() => {
  for (const directory of tempDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

const sqlText = (value: string): string => `'${value.replace(/'/g, "''")}'`;
const wordCount = (value: string): number => value.match(/\S+/gu)?.length ?? 0;

function sqlite(database: string, sql: string, json = false): string {
  const result = spawnSync('sqlite3', [...(json ? ['-json'] : []), database], {
    input: `.bail on\n${sql}\n`,
    encoding: 'utf8',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr.trim() || `sqlite3 exited ${result.status}`);
  return result.stdout;
}

function query<T>(database: string, sql: string): T[] {
  const output = sqlite(database, sql, true).trim();
  return output ? JSON.parse(output) as T[] : [];
}

function sourceDatabase(documents: FixtureDocument[]): { source: string; output: string } {
  const directory = mkdtempSync(join(tmpdir(), 'ticker-doc-converter-'));
  tempDirectories.push(directory);
  const source = join(directory, 'source.db');
  const output = join(directory, 'output.db');

  sqlite(source, `
    PRAGMA foreign_keys = ON;
    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
    INSERT INTO grdb_migrations VALUES ('v25_pending_stream_appends');
    CREATE TABLE streams (id TEXT PRIMARY KEY);
    CREATE TABLE stream_documents (
      stream_id TEXT PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
      markdown TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0,
      scroll_offset REAL NOT NULL DEFAULT 0,
      word_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE provenance_spans (
      span_id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
      start INTEGER NOT NULL,
      end INTEGER NOT NULL,
      origin TEXT NOT NULL,
      request_id TEXT,
      source_id TEXT,
      meta TEXT NOT NULL DEFAULT '{}',
      text_hash TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE TABLE pending_stream_appends (
      stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK (revision > 0),
      separator TEXT NOT NULL,
      fragment TEXT NOT NULL,
      raw_spans_json TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY (stream_id, revision)
    );
  `);

  for (const document of documents) {
    sqlite(source, `
      INSERT INTO streams VALUES (${sqlText(document.id)});
      INSERT INTO stream_documents
        (stream_id, markdown, created_at, updated_at, revision, word_count)
      VALUES (
        ${sqlText(document.id)},
        ${sqlText(document.markdown)},
        1000,
        1000,
        ${document.revision ?? 0},
        ${wordCount(document.markdown)}
      );
    `);
    for (const span of document.spans ?? []) {
      sqlite(source, `
        INSERT INTO provenance_spans
          (span_id, stream_id, start, end, origin, request_id, source_id, meta, text_hash, created_at)
        VALUES (
          ${sqlText(span.spanId)},
          ${sqlText(document.id)},
          ${span.start},
          ${span.end},
          ${sqlText(span.origin)},
          ${span.requestId ? sqlText(span.requestId) : 'NULL'},
          ${span.sourceId ? sqlText(span.sourceId) : 'NULL'},
          ${sqlText(span.meta)},
          ${sqlText(span.textHash)},
          ${Date.parse(span.createdAt) / 1000}
        );
      `);
    }
    for (const pending of document.pending ?? []) {
      sqlite(source, `
        INSERT INTO pending_stream_appends
          (stream_id, revision, separator, fragment, raw_spans_json)
        VALUES (
          ${sqlText(document.id)},
          ${pending.revision},
          ${sqlText(pending.separator)},
          ${sqlText(pending.fragment)},
          ${sqlText(typeof pending.rawSpans === 'string'
            ? pending.rawSpans
            : JSON.stringify(pending.rawSpans))}
        );
      `);
    }
  }

  return { source, output };
}

const rawSpan = (fragment: string): FixtureSpan => ({
  spanId: 'span-pending',
  start: 0,
  end: fragment.length,
  origin: 'ai',
  requestId: 'request-1',
  meta: '{"model":"test"}',
  textHash: fnv1a(fragment),
  createdAt: new Date(0).toISOString(),
});

describe('copy-only document conversion', () => {
  it('backs up a v25 source, migrates only the output, and writes one document truth', () => {
    const original = '# Heading\n\nA **bold** answer.';
    const { source, output } = sourceDatabase([{ id: 'stream-1', markdown: original }]);

    const report = convertDatabase(source, output);

    expect(report).toEqual([
      { streamId: 'stream-1', converted: true, spansKept: 0, legacyRowsFoldedIn: 0 },
    ]);
    expect(query<{ name: string }>(source, 'PRAGMA table_info(stream_documents);').map((row) => row.name))
      .not.toContain('doc_json');

    const [stored] = query<{
      markdown: string;
      docJson: string;
      docFormatVersion: number;
    }>(output, `
      SELECT markdown, doc_json AS docJson, doc_format_version AS docFormatVersion
      FROM stream_documents;
    `);
    const converted = tickerSchema.nodeFromJSON(JSON.parse(stored.docJson));
    expect(converted.eq(parseMarkdown(original))).toBe(true);
    expect(stored.markdown).toBe(serializeMarkdown(converted));
    expect(stored.docFormatVersion).toBe(1);
    expect(query<{ identifier: string }>(output, `
      SELECT identifier FROM grdb_migrations WHERE identifier = 'v26_canonical_stream_documents';
    `)).toHaveLength(1);
    expect(query<{ name: string }>(output, 'PRAGMA table_info(stream_append_inbox);').map((row) => row.name))
      .toEqual(['seq', 'append_id', 'stream_id', 'fragment', 'raw_spans_json', 'created_at']);
    expect(() => sqlite(output, `
      UPDATE stream_documents SET doc_format_version = NULL WHERE stream_id = 'stream-1';
    `)).toThrow(/CHECK constraint failed/);
  });

  it('folds legacy rows into the document and keeps every placed span', () => {
    const fragment = 'The **AI** wrote this.';
    const markdown = `Before\n\n${fragment}`;
    const { source, output } = sourceDatabase([{
      id: 'stream-pending',
      markdown,
      revision: 2,
      pending: [{ revision: 2, separator: '\n\n', fragment, rawSpans: [rawSpan(fragment)] }],
    }]);

    expect(convertDatabase(source, output)).toEqual([
      { streamId: 'stream-pending', converted: true, spansKept: 1, legacyRowsFoldedIn: 1 },
    ]);

    const [stored] = query<{ docJson: string }>(output, `
      SELECT doc_json AS docJson FROM stream_documents WHERE stream_id = 'stream-pending';
    `);
    const doc = tickerSchema.nodeFromJSON(JSON.parse(stored.docJson));
    const [span] = query<{ start: number; end: number; textHash: string }>(output, `
      SELECT start, end, text_hash AS textHash
      FROM provenance_spans WHERE stream_id = 'stream-pending';
    `);
    expect(doc.textBetween(span.start, span.end, '\n', '\n')).toBe('The AI wrote this.');
    expect(span.textHash).toBe(fnv1a('The AI wrote this.'));
  });

  it('keeps word_count derived from the rewritten Markdown', () => {
    const { source, output } = sourceDatabase([{ id: 'stream-count', markdown: '* * *' }]);

    convertDatabase(source, output);

    expect(query<{ markdown: string; wordCount: number }>(output, `
      SELECT markdown, word_count AS wordCount FROM stream_documents;
    `)).toEqual([{ markdown: '---', wordCount: 1 }]);
  });

  it('keeps a persisted PM-coordinate span only when its text still hashes', () => {
    const markdown = 'A **bold** answer.';
    const doc = parseMarkdown(markdown);
    const span = {
      ...rawSpan(markdown),
      spanId: 'span-existing',
      start: 1,
      end: doc.content.size - 1,
      textHash: fnv1a(doc.textBetween(1, doc.content.size - 1, '\n', '\n')),
    };
    const { source, output } = sourceDatabase([{ id: 'stream-span', markdown, spans: [span] }]);

    expect(convertDatabase(source, output)[0].spansKept).toBe(1);
    expect(query(output, "SELECT * FROM provenance_spans WHERE span_id = 'span-existing';")).toHaveLength(1);
  });

  it('aborts the whole run when a persisted span cannot be proven', () => {
    const markdown = 'A bold answer.';
    const { source, output } = sourceDatabase([
      { id: 'stream-good', markdown: 'Good' },
      {
        id: 'stream-bad',
        markdown,
        spans: [{ ...rawSpan(markdown), start: 1, end: 5, textHash: '00000000' }],
      },
    ]);

    expect(() => convertDatabase(source, output)).toThrow(/stream-bad.*hash/i);
    expect(() => readFileSync(output)).toThrow();
  });

  it('aborts when a persisted span is outside the PM document', () => {
    const markdown = 'Short';
    const { source, output } = sourceDatabase([{
      id: 'stream-bounds',
      markdown,
      spans: [{ ...rawSpan(markdown), start: 1, end: 999 }],
    }]);

    expect(() => convertDatabase(source, output)).toThrow(/stream-bounds.*out of bounds/i);
    expect(() => readFileSync(output)).toThrow();
  });

  it('aborts rather than dropping malformed raw span JSON', () => {
    const fragment = 'Append';
    const { source, output } = sourceDatabase([{
      id: 'stream-malformed',
      markdown: `Base\n\n${fragment}`,
      revision: 3,
      pending: [{
        revision: 3,
        separator: '\n\n',
        fragment,
        rawSpans: [{ spanId: 'missing-everything-else' }],
      }],
    }]);

    expect(() => convertDatabase(source, output)).toThrow(/stream-malformed.*raw span/i);
    expect(() => readFileSync(output)).toThrow();
  });

  it('aborts when a well-formed raw span cannot be placed', () => {
    const fragment = 'Append';
    const { source, output } = sourceDatabase([{
      id: 'stream-unplaceable',
      markdown: `Base\n\n${fragment}`,
      revision: 3,
      pending: [{
        revision: 3,
        separator: '\n\n',
        fragment,
        rawSpans: [{ ...rawSpan(fragment), textHash: '00000000' }],
      }],
    }]);

    expect(() => convertDatabase(source, output)).toThrow(/stream-unplaceable.*cannot be placed/i);
    expect(() => readFileSync(output)).toThrow();
  });

  it('aborts when the legacy rows do not prove the markdown suffix', () => {
    const { source, output } = sourceDatabase([{
      id: 'stream-drifted',
      markdown: 'Base\n\nDifferent',
      revision: 2,
      pending: [{ revision: 2, separator: '\n\n', fragment: 'Claimed', rawSpans: [] }],
    }]);

    expect(() => convertDatabase(source, output)).toThrow(/stream-drifted.*suffixMismatch/);
    expect(() => readFileSync(output)).toThrow();
  });

  it('refuses the same source and output path before touching the source', () => {
    const { source } = sourceDatabase([{ id: 'stream-1', markdown: 'Untouched' }]);

    expect(() => convertDatabase(source, source)).toThrow(/different paths/i);
    expect(query<{ markdown: string }>(source, 'SELECT markdown FROM stream_documents;')[0].markdown)
      .toBe('Untouched');
  });

  it('refuses to overwrite an existing output', () => {
    const { source, output } = sourceDatabase([{ id: 'stream-1', markdown: 'Untouched' }]);
    writeFileSync(output, 'keep me');

    expect(() => convertDatabase(source, output)).toThrow(/already exists/i);
    expect(readFileSync(output, 'utf8')).toBe('keep me');
  });

  it('refuses a database whose canonical columns are only half present', () => {
    const { source, output } = sourceDatabase([{ id: 'stream-1', markdown: 'Untouched' }]);
    sqlite(source, 'ALTER TABLE stream_documents ADD COLUMN doc_json TEXT;');

    expect(() => convertDatabase(source, output)).toThrow(/only half present/i);
    expect(() => readFileSync(output)).toThrow();
  });
});

describe('strict conversion proofs', () => {
  it('rejects every malformed part of a raw span instead of filtering it out', () => {
    const valid = rawSpan('text');
    expect(decodeRawSpansStrict(JSON.stringify([valid]))).toEqual([valid]);

    for (const malformed of [
      'not json',
      '{}',
      JSON.stringify([{ ...valid, spanId: 1 }]),
      JSON.stringify([{ ...valid, origin: 'unknown' }]),
      JSON.stringify([{ ...valid, meta: 'not json' }]),
      JSON.stringify([{ ...valid, createdAt: 'not a date' }]),
    ]) {
      expect(() => decodeRawSpansStrict(malformed)).toThrow(/raw span/i);
    }
  });

  it('uses exact ProseMirror document equality', () => {
    expect(() => assertDocumentEqual(
      parseMarkdown('one'),
      parseMarkdown('two'),
      'documents differ',
    )).toThrow('documents differ');
  });
});
