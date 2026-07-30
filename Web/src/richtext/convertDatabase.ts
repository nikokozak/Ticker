import { spawnSync } from 'node:child_process';
import { existsSync, realpathSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Node as ProseNode } from 'prosemirror-model';
import { fnv1a } from '../utils/fnv1a';
import { parseMarkdown, serializeMarkdown } from './markdown';
import {
  decodeRawSpansStrict,
  placeFragmentSpan,
  planReplay,
  type PendingAppend,
} from './pendingAppends';
import type { ProvenanceSpan } from './provenance';
import { tickerSchema } from './schema';

export { decodeRawSpansStrict } from './pendingAppends';

export interface ConversionReportRow {
  streamId: string;
  converted: true;
  spansKept: number;
  legacyRowsFoldedIn: number;
}

interface DocumentRow {
  streamId: string;
  markdown: string;
  revision: number;
}

interface StoredSpanRow {
  spanId: unknown;
  streamId: unknown;
  start: unknown;
  end: unknown;
  origin: unknown;
  requestId: unknown;
  sourceId: unknown;
  meta: unknown;
  textHash: unknown;
  createdAt: unknown;
}

interface PendingRow {
  streamId: unknown;
  revision: unknown;
  separator: unknown;
  fragment: unknown;
  rawSpansJSON: unknown;
}

interface ConvertedStream {
  streamId: string;
  markdown: string;
  docJSON: string;
  spans: ProvenanceSpan[];
  report: ConversionReportRow;
}

const ORIGINS: ProvenanceSpan['origin'][] = ['ai', 'source', 'capture'];

function sqlite(database: string, sql: string, options: { json?: boolean; readOnly?: boolean } = {}): string {
  const result = spawnSync(
    'sqlite3',
    [...(options.readOnly ? ['-readonly'] : []), ...(options.json ? ['-json'] : []), database],
    { input: `.bail on\n${sql}\n`, encoding: 'utf8' },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr.trim() || `sqlite3 exited ${result.status}`);
  return result.stdout;
}

function query<T>(database: string, sql: string): T[] {
  const output = sqlite(database, sql, { json: true }).trim();
  return output ? JSON.parse(output) as T[] : [];
}

function sqlText(value: string): string {
  return `CAST(X'${Buffer.from(value, 'utf8').toString('hex')}' AS TEXT)`;
}

function sqlNullableText(value: string | undefined): string {
  return value === undefined ? 'NULL' : sqlText(value);
}

const wordCount = (value: string): number => value.match(/\S+/gu)?.length ?? 0;

function objectFromJSON(value: string, label: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${label} is not a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

export function assertDocumentEqual(actual: ProseNode, expected: ProseNode, message: string): void {
  if (!actual.eq(expected)) throw new Error(message);
}

function storedSpan(row: StoredSpanRow, streamId: string): ProvenanceSpan {
  if (typeof row.spanId !== 'string' || row.spanId.length === 0
      || row.streamId !== streamId
      || !Number.isInteger(row.start) || !Number.isInteger(row.end)
      || typeof row.origin !== 'string' || !ORIGINS.includes(row.origin as ProvenanceSpan['origin'])
      || (row.requestId !== null && typeof row.requestId !== 'string')
      || (row.sourceId !== null && typeof row.sourceId !== 'string')
      || typeof row.meta !== 'string'
      || typeof row.textHash !== 'string'
      || typeof row.createdAt !== 'number' || !Number.isFinite(row.createdAt)) {
    throw new Error('Malformed persisted provenance span');
  }

  return {
    spanId: row.spanId,
    from: row.start as number,
    to: row.end as number,
    origin: row.origin as ProvenanceSpan['origin'],
    requestId: row.requestId === null ? undefined : row.requestId as string,
    sourceId: row.sourceId === null ? undefined : row.sourceId as string,
    meta: objectFromJSON(row.meta, 'Persisted provenance metadata'),
    textHash: row.textHash,
    createdAt: row.createdAt * 1000,
  };
}

function proveSpan(span: ProvenanceSpan, doc: ProseNode): void {
  if (!Number.isInteger(span.from) || !Number.isInteger(span.to)
      || span.from < 0 || span.from >= span.to || span.to > doc.content.size) {
    throw new Error(`Provenance span ${span.spanId} is out of bounds`);
  }
  const text = doc.textBetween(span.from, span.to, '\n', '\n');
  if (fnv1a(text) !== span.textHash) {
    throw new Error(`Provenance span ${span.spanId} hash does not match its document text`);
  }
}

function pendingAppend(row: PendingRow): PendingAppend {
  if (!Number.isInteger(row.revision)
      || typeof row.separator !== 'string'
      || typeof row.fragment !== 'string'
      || typeof row.rawSpansJSON !== 'string') {
    throw new Error('Malformed pending append row');
  }
  return {
    revision: row.revision as number,
    separator: row.separator,
    fragment: row.fragment,
    rawSpans: decodeRawSpansStrict(row.rawSpansJSON),
  };
}

function convertStream(
  row: DocumentRow,
  storedRows: StoredSpanRow[],
  pendingRows: PendingRow[],
): ConvertedStream {
  try {
    const pending = pendingRows.map(pendingAppend);
    const plan = planReplay(row.markdown, row.revision, pending);
    if (!plan.ok) throw new Error(`legacy append proof failed: ${plan.reason}`);

    let doc = parseMarkdown(plan.baseMarkdown);
    const placed: ProvenanceSpan[] = [];
    for (const append of plan.appends) {
      const fragment = parseMarkdown(append.fragment);
      const insertedAt = doc.content.size;
      doc = doc.copy(doc.content.append(fragment.content));
      for (const raw of append.spans) {
        const span = placeFragmentSpan(raw, append.fragment, insertedAt, doc);
        if (!span) throw new Error(`raw span ${raw.spanId} cannot be placed`);
        placed.push(span);
      }
    }

    const existing = storedRows.map((span) => storedSpan(span, row.streamId));
    const spans = [...existing, ...placed];

    assertDocumentEqual(
      doc,
      parseMarkdown(row.markdown),
      'converted document does not equal the original Markdown document',
    );
    const docJSON = JSON.parse(JSON.stringify(doc.toJSON())) as unknown;
    assertDocumentEqual(
      tickerSchema.nodeFromJSON(docJSON),
      doc,
      'document JSON does not round-trip through the schema',
    );
    const markdown = serializeMarkdown(doc);
    assertDocumentEqual(
      parseMarkdown(markdown),
      doc,
      'derived Markdown does not round-trip to the converted document',
    );

    for (const span of spans) proveSpan(span, doc);

    return {
      streamId: row.streamId,
      markdown,
      docJSON: JSON.stringify(docJSON),
      spans,
      report: {
        streamId: row.streamId,
        converted: true,
        spansKept: spans.length,
        legacyRowsFoldedIn: pending.length,
      },
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Stream ${row.streamId}: ${message}`);
  }
}

function conversionSQL(converted: ConvertedStream[], migrateV26: boolean): string {
  const statements = ['PRAGMA foreign_keys = ON;', 'BEGIN IMMEDIATE;'];
  if (migrateV26) {
    // ponytail: this one-off repeats v26's DDL; delete the converter at cutover
    // instead of building a cross-language migration framework for one migration.
    statements.push(`
      ALTER TABLE stream_documents ADD COLUMN doc_json TEXT;
      ALTER TABLE stream_documents ADD COLUMN doc_format_version INTEGER
        CHECK ((doc_json IS NULL) = (doc_format_version IS NULL));
      CREATE TABLE stream_append_inbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        append_id TEXT NOT NULL UNIQUE,
        stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
        fragment TEXT NOT NULL,
        raw_spans_json TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL
      );
      CREATE INDEX idx_append_inbox_stream ON stream_append_inbox (stream_id, seq);
      INSERT INTO grdb_migrations (identifier) VALUES ('v26_canonical_stream_documents');
    `);
  }

  for (const stream of converted) {
    statements.push(`
      UPDATE stream_documents
      SET markdown = ${sqlText(stream.markdown)},
          word_count = ${wordCount(stream.markdown)},
          doc_json = ${sqlText(stream.docJSON)},
          doc_format_version = 1
      WHERE stream_id = ${sqlText(stream.streamId)};
      DELETE FROM provenance_spans WHERE stream_id = ${sqlText(stream.streamId)};
      DELETE FROM pending_stream_appends WHERE stream_id = ${sqlText(stream.streamId)};
    `);
    for (const span of stream.spans) {
      statements.push(`
        INSERT INTO provenance_spans
          (span_id, stream_id, start, end, origin, request_id, source_id, meta, text_hash, created_at)
        VALUES (
          ${sqlText(span.spanId)},
          ${sqlText(stream.streamId)},
          ${span.from},
          ${span.to},
          ${sqlText(span.origin)},
          ${sqlNullableText(span.requestId)},
          ${sqlNullableText(span.sourceId)},
          ${sqlText(JSON.stringify(span.meta))},
          ${sqlText(span.textHash)},
          ${span.createdAt / 1000}
        );
      `);
    }
  }
  statements.push('COMMIT;');
  return statements.join('\n');
}

export function convertDatabase(source: string, output: string): ConversionReportRow[] {
  const sourcePath = realpathSync(resolve(source));
  const outputPath = resolve(output);
  if (sourcePath === outputPath
      || (existsSync(outputPath) && realpathSync(outputPath) === sourcePath)) {
    throw new Error('Source and output must be different paths');
  }
  if (existsSync(outputPath)) throw new Error(`Output already exists: ${outputPath}`);

  try {
    sqlite(sourcePath, `.backup ${JSON.stringify(outputPath)}`, { readOnly: true });

    const columns = query<{ name: string }>(outputPath, 'PRAGMA table_info(stream_documents);')
      .map((column) => column.name);
    const hasJSON = columns.includes('doc_json');
    const hasVersion = columns.includes('doc_format_version');
    if (hasJSON !== hasVersion) throw new Error('Canonical document columns are only half present');
    const migrateV26 = !hasJSON;

    const documents = query<DocumentRow>(outputPath, `
      SELECT stream_id AS streamId, markdown, revision
      FROM stream_documents
      ORDER BY stream_id;
    `);
    const spans = query<StoredSpanRow>(outputPath, `
      SELECT
        span_id AS spanId,
        stream_id AS streamId,
        start,
        end,
        origin,
        request_id AS requestId,
        source_id AS sourceId,
        meta,
        text_hash AS textHash,
        created_at AS createdAt
      FROM provenance_spans
      ORDER BY stream_id, start, end, span_id;
    `);
    const pending = query<PendingRow>(outputPath, `
      SELECT
        stream_id AS streamId,
        revision,
        separator,
        fragment,
        raw_spans_json AS rawSpansJSON
      FROM pending_stream_appends
      ORDER BY stream_id, revision;
    `);

    const converted = documents.map((document) => convertStream(
      document,
      spans.filter((span) => span.streamId === document.streamId),
      pending.filter((append) => append.streamId === document.streamId),
    ));
    sqlite(outputPath, conversionSQL(converted, migrateV26));
    return converted.map((stream) => stream.report);
  } catch (error) {
    rmSync(outputPath, { force: true });
    throw error;
  }
}
