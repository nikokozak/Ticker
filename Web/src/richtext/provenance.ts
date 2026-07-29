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
 * while editing, and would have to be recomputed on every keystroke. Parsing is
 * deterministic, so a PM position computed from the same markdown is the same
 * position every time — stable across save and reload.
 *
 * A span is dropped as soon as its own text is edited. "The AI wrote this" stops
 * being true the moment the user rewrites it, and a span that survived editing is
 * exactly the stale highlight that was reported as broken.
 */

export interface ProvenanceSpan {
  spanId: string;
  from: number;
  to: number;
  origin: 'ai' | 'source' | 'capture';
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

/** True when a change fell strictly INSIDE the span rather than beside it. */
function spanWasEdited(span: ProvenanceSpan, tr: Transaction): boolean {
  let edited = false;
  for (const step of tr.steps) {
    const map = step.getMap();
    map.forEach((fromA, toA) => {
      if (fromA === toA) {
        // A pure insertion only counts when it lands strictly within the span;
        // typing against either edge is writing next to it, not rewriting it.
        if (fromA > span.from && fromA < span.to) edited = true;
      } else if (fromA < span.to && toA > span.from) {
        edited = true;
      }
    });
  }
  return edited;
}

function mapSpans(spans: ProvenanceSpan[], tr: Transaction): ProvenanceSpan[] {
  if (!tr.docChanged) return spans;

  const kept: ProvenanceSpan[] = [];
  for (const span of spans) {
    if (spanWasEdited(span, tr)) continue;
    // Bias each edge INWARDS, so text typed against a boundary stays outside the
    // span. Writing next to what the AI wrote is not the AI having written it.
    const from = tr.mapping.map(span.from, 1);
    const to = tr.mapping.map(span.to, -1);
    if (to - from >= MIN_SPAN_LENGTH) kept.push({ ...span, from, to });
  }
  return kept;
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
      decorations: (state) => DecorationSet.create(
        state.doc,
        provenanceSpans(state).map((span) => Decoration.inline(span.from, span.to, {
          class: `richtext-provenance richtext-provenance-${span.origin}`,
          'data-span-id': span.spanId,
        })),
      ),
    },
  });
}
