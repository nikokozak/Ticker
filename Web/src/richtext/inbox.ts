import type { Node as ProseNode } from 'prosemirror-model';
import { parseMarkdown } from './markdown';
import { decodeRawSpansStrict, placeFragmentSpan } from './pendingAppends';
import type { ProvenanceSpan } from './provenance';

export interface InboxAppend {
  seq: number;
  appendId: string;
  fragment: string;
  rawSpansJSON: string;
  createdAt: string;
}

export type InboxReduction =
  | {
    ok: true;
    doc: ProseNode;
    spans: ProvenanceSpan[];
    consumedThrough: number | null;
  }
  | {
    ok: false;
    reason: 'emptyFragment' | 'malformedSpans' | 'duplicateSpan' | 'spanUnplaceable';
  };

/**
 * Reduce the durable inbox into a COPY of the canonical document.
 *
 * `seq` is global, so gaps are ordinary; sorting is the only ordering proof this
 * needs. Nothing touches the live editor until every fragment and span succeeds.
 */
export function reduceAppendInbox(
  base: ProseNode,
  existing: readonly ProvenanceSpan[],
  inbox: readonly InboxAppend[],
): InboxReduction {
  const rows = [...inbox].sort((left, right) => left.seq - right.seq);
  if (!rows.length) return { ok: true, doc: base, spans: [], consumedThrough: null };

  let doc = base;
  const spans: ProvenanceSpan[] = [];
  const knownSpanIds = new Set(existing.map((span) => span.spanId));

  for (const row of rows) {
    if (!row.fragment.trim()) return { ok: false, reason: 'emptyFragment' };

    let rawSpans: ReturnType<typeof decodeRawSpansStrict>;
    try {
      rawSpans = decodeRawSpansStrict(row.rawSpansJSON);
    } catch {
      return { ok: false, reason: 'malformedSpans' };
    }

    const fragment = parseMarkdown(row.fragment);
    const insertedAt = doc.content.size;
    const next = doc.copy(doc.content.append(fragment.content));
    for (const raw of rawSpans) {
      if (knownSpanIds.has(raw.spanId)) return { ok: false, reason: 'duplicateSpan' };
      const placed = placeFragmentSpan(raw, row.fragment, insertedAt, next);
      if (!placed) return { ok: false, reason: 'spanUnplaceable' };
      knownSpanIds.add(placed.spanId);
      spans.push(placed);
    }
    doc = next;
  }

  return {
    ok: true,
    doc,
    spans,
    consumedThrough: rows[rows.length - 1].seq,
  };
}
