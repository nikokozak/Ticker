import { Plugin, PluginKey, type EditorState, type Transaction } from 'prosemirror-state';
import { Decoration, DecorationSet } from 'prosemirror-view';
import type { Node as ProseNode } from 'prosemirror-model';
import { fnv1a } from '../utils/fnv1a';

/**
 * Which parts of a stream the AI wrote, and where they came from. This is what the
 * provenance xray shows and what the hover popover reads.
 *
 * Positions are ProseMirror positions, not offsets into the markdown. That is the
 * whole change from the CodeMirror version, and it is what makes the feature
 * possible at all now: the markdown is derived, so an offset into it means nothing
 * while editing, and would have to be recomputed on every keystroke. The stored
 * ProseMirror JSON recreates the same tree, so these positions survive reload.
 *
 * AI/source attribution is dropped as soon as its own text is edited. Legacy thread
 * anchors are different: they mark a line of thought, so they map through edits and
 * retain the original hash to tell the caller whether the quoted wording is stale.
 */

export interface ProvenanceSpan {
  spanId: string;
  from: number;
  to: number;
  origin: 'ai' | 'source' | 'capture' | 'thread';
  requestId?: string;
  sourceId?: string;
  meta: Record<string, unknown>;
  textHash: string;
  createdAt: number;
}

/** Shorter than this and a span is noise — a word boundary, not a contribution. */
const MIN_SPAN_LENGTH = 3;

type ProvenanceMessage =
  | { kind: 'set'; spans: ProvenanceSpan[] }
  | { kind: 'add'; spans: ProvenanceSpan[] }
  | { kind: 'dissolve'; spanIds: string[] };

const provenanceKey = new PluginKey<ProvenanceSpan[]>('tickerProvenance');

/** Replace every span, as loading a stream does. */
export const setProvenanceSpans = (tr: Transaction, spans: ProvenanceSpan[]): Transaction =>
  tr.setMeta(provenanceKey, { kind: 'set', spans });

/** Record new spans, as finishing an AI write does. */
export const addProvenanceSpans = (tr: Transaction, spans: ProvenanceSpan[]): Transaction =>
  tr.setMeta(provenanceKey, { kind: 'add', spans });

/** Forget spans by id, as accepting or dismissing them does. */
export const dissolveProvenanceSpans = (tr: Transaction, spanIds: string[]): Transaction =>
  tr.setMeta(provenanceKey, { kind: 'dissolve', spanIds });

export function provenanceSpans(state: EditorState): ProvenanceSpan[] {
  return provenanceKey.getState(state) ?? [];
}

/** The span covering a position, for the hover popover. */
export function provenanceSpanAt(state: EditorState, pos: number): ProvenanceSpan | null {
  return provenanceSpans(state).find((span) => pos >= span.from && pos <= span.to) ?? null;
}

/** The text a span covers, which is also what its hash is taken over. */
export function provenanceText(doc: ProseNode, span: { from: number; to: number }): string {
  return doc.textBetween(span.from, span.to, '\n', '\n');
}

export function hashProvenanceText(doc: ProseNode, span: { from: number; to: number }): string {
  return fnv1a(provenanceText(doc, span));
}

/**
 * Follow one span through a transaction, step by step.
 *
 * Step by step is the whole point: each step's map is expressed in the coordinates
 * of the document as it was BEFORE that step, so comparing every step against the
 * span's ORIGINAL position is wrong the moment a transaction has more than one.
 * Insert before a span and then edit inside its shifted range in the same
 * transaction, and the edit is missed — the user's own text stays attributed to
 * the AI. Paste and structural commands routinely emit several steps at once.
 *
 * Each edge maps INWARDS, so text typed against a boundary stays outside the span.
 * Writing next to what the AI wrote is not the AI having written it.
 */
function followSpan(span: ProvenanceSpan, tr: Transaction): ProvenanceSpan | null {
  let { from, to } = span;

  for (const step of tr.steps) {
    const map = step.getMap();
    if (span.origin === 'thread') {
      // A legacy thread stays attached to the thought as that thought is revised. The
      // original hash still tells the UI that its quote is stale; only deleting
      // the passage entirely removes the marker.
      from = map.map(from, -1);
      to = map.map(to, 1);
      continue;
    }
    let edited = false;
    map.forEach((fromA, toA) => {
      // A pure insertion only counts when it lands strictly within the span;
      // typing against either edge is writing next to it, not rewriting it.
      if (fromA === toA) {
        if (fromA > from && fromA < to) edited = true;
      } else if (fromA < to && toA > from) {
        edited = true;
      }
    });
    if (edited) return null;

    from = map.map(from, 1);
    to = map.map(to, -1);
  }

  return to - from >= MIN_SPAN_LENGTH ? { ...span, from, to } : null;
}

function mapSpans(spans: ProvenanceSpan[], tr: Transaction): ProvenanceSpan[] {
  if (!tr.docChanged) return spans;
  return spans.map((span) => followSpan(span, tr)).filter((span): span is ProvenanceSpan => span !== null);
}

/** Drop spans that do not fit the document, which is what a bad restore looks like. */
function validSpans(spans: ProvenanceSpan[], doc: ProseNode): ProvenanceSpan[] {
  return spans.filter((span) => (
    span.from >= 0 && span.to <= doc.content.size && span.to - span.from >= MIN_SPAN_LENGTH
  ));
}

export function provenance(): Plugin<ProvenanceSpan[]> {
  return new Plugin<ProvenanceSpan[]>({
    key: provenanceKey,
    state: {
      init: () => [],
      apply(tr, current, _old, newState) {
        const mapped = mapSpans(current, tr);
        const meta = tr.getMeta(provenanceKey) as ProvenanceMessage | undefined;
        if (!meta) return mapped;

        if (meta.kind === 'set') return validSpans(meta.spans, newState.doc);
        if (meta.kind === 'add') return [...mapped, ...validSpans(meta.spans, newState.doc)];
        const dropped = new Set(meta.spanIds);
        return mapped.filter((span) => !dropped.has(span.spanId));
      },
    },
    props: {
      decorations: (state) => {
        const spans = provenanceSpans(state);
        const decorations = spans.filter((span) => span.origin !== 'thread').map((span) => Decoration.inline(span.from, span.to, {
          class: `richtext-provenance richtext-provenance-${span.origin}`,
          'data-span-id': span.spanId,
        }));
        return DecorationSet.create(state.doc, decorations);
      },
    },
  });
}

/**
 * The wire shape. `start`/`end` keep their names but now hold ProseMirror
 * positions rather than offsets into the markdown — the same integers, measured
 * against the document instead of its serialisation. Existing rows therefore need
 * a migration; there is no way to tell the two apart by looking.
 */
export interface ProvenanceSpanJSON {
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

const ORIGINS: ProvenanceSpan['origin'][] = ['ai', 'source', 'capture', 'thread'];

export function spanFromJSON(json: ProvenanceSpanJSON): ProvenanceSpan {
  let meta: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(json.meta || '{}');
    if (parsed && typeof parsed === 'object') meta = parsed as Record<string, unknown>;
  } catch {
    meta = {}; // a span with unreadable metadata is still a span
  }

  const origin = ORIGINS.find((known) => known === json.origin) ?? 'ai';
  return {
    spanId: json.spanId,
    from: json.start,
    to: json.end,
    origin,
    requestId: json.requestId,
    sourceId: json.sourceId,
    meta,
    textHash: json.textHash,
    createdAt: Date.parse(json.createdAt) || 0,
  };
}

export function spanToJSON(span: ProvenanceSpan): ProvenanceSpanJSON {
  return {
    spanId: span.spanId,
    start: span.from,
    end: span.to,
    origin: span.origin,
    requestId: span.requestId,
    sourceId: span.sourceId,
    meta: JSON.stringify(span.meta ?? {}),
    textHash: span.textHash,
    createdAt: new Date(span.createdAt || 0).toISOString(),
  };
}
