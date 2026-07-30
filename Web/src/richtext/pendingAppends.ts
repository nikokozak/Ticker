import type { Node as ProseNode } from 'prosemirror-model';
import { fnv1a } from '../utils/fnv1a';
import { parseMarkdown } from './markdown';
import { spanFromJSON, type ProvenanceSpan, type ProvenanceSpanJSON } from './provenance';

/**
 * Converting the provenance of an append that happened while no editor was open.
 *
 * The store cannot express those coordinates: they are ProseMirror document
 * positions, and knowing one means parsing the document. So it keeps each append
 * verbatim — the exact fragment, and offsets into that fragment — and this turns
 * them into document positions the first time an editor opens the stream.
 *
 * Every step is a proof rather than a guess, and any step that cannot be proven
 * abandons the whole replay. A half-converted span points at the wrong text and
 * says the AI wrote something it did not, which is worse than no highlighting at
 * all — and the rows are kept, so a later version can still do it correctly.
 */

/** A span as the store holds it: offsets into its own fragment. */
export interface RawFragmentSpan extends Omit<ProvenanceSpanJSON, 'start' | 'end'> {
  start: number;
  end: number;
}

export interface PendingAppend {
  revision: number;
  separator: string;
  fragment: string;
  rawSpans: RawFragmentSpan[];
}

export type ReplayFailure =
  | 'revisionGap'
  | 'revisionMismatch'
  | 'suffixMismatch';

export type ReplayPlan =
  | { ok: true; baseMarkdown: string; appends: Array<{ fragment: string; spans: RawFragmentSpan[] }> }
  | { ok: false; reason: ReplayFailure };

const ORIGINS: ProvenanceSpan['origin'][] = ['ai', 'source', 'capture'];

/** Strict at migration and inbox boundaries, where dropping one row loses history. */
export function decodeRawSpansStrict(json: string): RawFragmentSpan[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error('Malformed raw span JSON');
  }
  if (!Array.isArray(parsed)) throw new Error('Malformed raw span JSON: expected an array');

  return parsed.map((value, index) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error(`Malformed raw span ${index}: expected an object`);
    }
    const row = value as Record<string, unknown>;
    if (typeof row.spanId !== 'string' || row.spanId.length === 0
        || !Number.isInteger(row.start) || !Number.isInteger(row.end)
        || typeof row.origin !== 'string' || !ORIGINS.includes(row.origin as ProvenanceSpan['origin'])
        || typeof row.meta !== 'string'
        || typeof row.textHash !== 'string'
        || typeof row.createdAt !== 'string' || !Number.isFinite(Date.parse(row.createdAt))
        || ('requestId' in row && typeof row.requestId !== 'string')
        || ('sourceId' in row && typeof row.sourceId !== 'string')) {
      throw new Error(`Malformed raw span ${index}`);
    }
    try {
      const meta: unknown = JSON.parse(row.meta);
      if (!meta || typeof meta !== 'object' || Array.isArray(meta)) throw new Error();
    } catch {
      throw new Error(`Malformed raw span ${index} metadata`);
    }
    return row as unknown as RawFragmentSpan;
  });
}

/** Decode the JSON the store carries, dropping anything malformed. */
export function parseRawSpans(json: string): RawFragmentSpan[] {
  try {
    return decodeRawSpansStrict(json || '[]');
  } catch {
    return [];
  }
}

/**
 * Peel the pending fragments off the end of the stored markdown.
 *
 * The rows have to be contiguous and end at the document's revision, and each
 * fragment has to be exactly what the end of the document says it is. Anything
 * else means the sequence is not what it claims, and there is no safe repair.
 */
export function planReplay(
  markdown: string,
  revision: number,
  pending: PendingAppend[],
): ReplayPlan {
  const rows = [...pending].sort((a, b) => a.revision - b.revision);
  if (rows.length === 0) return { ok: true, baseMarkdown: markdown, appends: [] };

  if (rows[rows.length - 1].revision !== revision) return { ok: false, reason: 'revisionMismatch' };
  for (let i = 1; i < rows.length; i += 1) {
    if (rows[i].revision !== rows[i - 1].revision + 1) return { ok: false, reason: 'revisionGap' };
  }

  let base = markdown;
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    const suffix = `${rows[i].separator}${rows[i].fragment}`;
    if (!base.endsWith(suffix)) return { ok: false, reason: 'suffixMismatch' };
    base = base.slice(0, base.length - suffix.length);
  }

  return {
    ok: true,
    baseMarkdown: base,
    appends: rows.map((row) => ({ fragment: row.fragment, spans: row.rawSpans })),
  };
}

/** The first and last inline positions in a parsed fragment, in its own coordinates. */
function inlineRange(doc: ProseNode): { from: number; to: number } | null {
  let from = -1;
  let to = -1;
  doc.descendants((node: ProseNode, pos: number) => {
    if (!node.isText && !node.isLeaf) return true;
    if (from < 0) from = pos;
    to = pos + node.nodeSize;
    return true;
  });
  return from < 0 ? null : { from, to };
}

/**
 * Turn one fragment-relative span into a document one.
 *
 * The proofs, in order:
 *   - it starts at the fragment's start, which is the only thing the producers
 *     ever record and the only thing this can place without guessing;
 *   - its offsets are inside the fragment and its stored hash matches the raw text
 *     it claims, so the row has not drifted from the fragment;
 *   - the text it covers parses to a COMPLETE top-level prefix of the fragment.
 *     Without that a span could end halfway through a block, and there is no
 *     document position for half a paragraph.
 */
export function placeFragmentSpan(
  raw: RawFragmentSpan,
  fragment: string,
  insertedAt: number,
  doc: ProseNode,
): ProvenanceSpan | null {
  if (raw.start !== 0 || raw.end <= raw.start || raw.end > fragment.length) return null;

  const covered = fragment.slice(raw.start, raw.end);
  if (fnv1a(covered) !== raw.textHash) return null;

  const prefix = parseMarkdown(covered);
  const whole = parseMarkdown(fragment);
  if (prefix.childCount === 0 || prefix.childCount > whole.childCount) return null;
  for (let i = 0; i < prefix.childCount; i += 1) {
    if (!prefix.child(i).eq(whole.child(i))) return null;
  }

  const range = inlineRange(prefix);
  if (!range) return null;

  const from = insertedAt + range.from;
  const to = insertedAt + range.to;
  if (to > doc.content.size) return null;

  return {
    ...spanFromJSON({ ...raw, start: from, end: to }),
    from,
    to,
    // Rehashed over the DOCUMENT text, which is what every later check compares.
    textHash: fnv1a(doc.textBetween(from, to, '\n', '\n')),
  };
}
