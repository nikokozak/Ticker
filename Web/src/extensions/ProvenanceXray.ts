import { RangeSetBuilder, Transaction, type Extension } from '@codemirror/state';
import {
  Decoration,
  EditorView,
  ViewPlugin,
  hoverTooltip,
  type DecorationSet,
  type Tooltip,
  type ViewUpdate,
} from '@codemirror/view';
import type { SourceReference } from '../types';
import type { AIExchangeJSON } from '../types';
import { currentSpans, dissolveSpans, type Span } from './ProvenanceField';

export interface ProvenanceRange {
  from: number;
  to: number;
}

export interface ProvenanceDecorationRange extends ProvenanceRange {
  className: string;
  span: Span;
}

export interface ProvenanceXrayOptions {
  sources: SourceReference[];
  isAiThinking: boolean;
  loadExchange: (requestId: string) => Promise<{ exchange: AIExchangeJSON | null }>;
  onShowExchange: (exchange: AIExchangeJSON, span: Span) => void;
  onRedevelop: (span: Span, exchange: AIExchangeJSON) => void;
  onOpenSource: (sourceId: string) => void;
}

function classForOrigin(origin: Span['origin']): string {
  switch (origin) {
    case 'source':
      return 'cm-prov-source';
    case 'capture':
      return 'cm-prov-capture';
    case 'ai':
    default:
      return 'cm-prov-ai';
  }
}

export const AI_TINT_VARIANTS = 5;

/** Round-robin tint variants over exchanges in document order, so neighboring
 * exchanges always read as distinct. Deterministic: stable across scroll/reload. */
function aiVariantClassByRequest(spans: Span[]): Map<string, string> {
  const firstStart = new Map<string, number>();
  for (const span of spans) {
    if (span.origin !== 'ai' || !span.requestId) continue;
    const seen = firstStart.get(span.requestId);
    if (seen === undefined || span.start < seen) firstStart.set(span.requestId, span.start);
  }
  const ordered = [...firstStart.entries()].sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]));
  return new Map(ordered.map(([requestId], index) => [requestId, ` cm-prov-ai--v${index % AI_TINT_VARIANTS}`]));
}

function subtractRanges(range: ProvenanceRange, skipRanges: readonly ProvenanceRange[]): ProvenanceRange[] {
  let pieces = [range];

  for (const skip of skipRanges) {
    const next: ProvenanceRange[] = [];
    for (const piece of pieces) {
      if (skip.to <= piece.from || skip.from >= piece.to) {
        next.push(piece);
        continue;
      }
      if (skip.from > piece.from) next.push({ from: piece.from, to: Math.min(skip.from, piece.to) });
      if (skip.to < piece.to) next.push({ from: Math.max(skip.to, piece.from), to: piece.to });
    }
    pieces = next;
  }

  return pieces.filter((piece) => piece.to > piece.from);
}

export function buildProvenanceDecorationRanges(
  spans: Span[],
  visibleRanges: readonly ProvenanceRange[],
  skipRanges: readonly ProvenanceRange[] = []
): ProvenanceDecorationRange[] {
  const ranges: ProvenanceDecorationRange[] = [];
  const variantByRequest = aiVariantClassByRequest(spans);

  for (const visible of visibleRanges) {
    for (const span of spans) {
      const from = Math.max(span.start, visible.from);
      const to = Math.min(span.end, visible.to);
      if (to <= from) continue;

      const variant = span.origin === 'ai' && span.requestId ? variantByRequest.get(span.requestId) ?? '' : '';
      for (const piece of subtractRanges({ from, to }, skipRanges)) {
        ranges.push({
          ...piece,
          className: classForOrigin(span.origin) + variant,
          span,
        });
      }
    }
  }

  return ranges.sort((a, b) => a.from - b.from || a.to - b.to || a.span.spanId.localeCompare(b.span.spanId));
}

function atomicRangesInView(view: EditorView): ProvenanceRange[] {
  const ranges: ProvenanceRange[] = [];
  for (const provider of view.state.facet(EditorView.atomicRanges)) {
    provider(view).between(view.viewport.from, view.viewport.to, (from, to) => {
      ranges.push({ from, to });
    });
  }
  return ranges;
}

function buildDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const range of buildProvenanceDecorationRanges(currentSpans(view.state), view.visibleRanges, atomicRangesInView(view))) {
    builder.add(range.from, range.to, Decoration.mark({ class: range.className }));
  }
  return builder.finish();
}

function relativeDate(timestamp: number, now = Date.now()): string {
  const seconds = Math.max(0, Math.round((now - timestamp) / 1000));
  if (seconds < 60) return 'now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(timestamp).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function textMeta(value: unknown, fallback: string): string {
  return typeof value === 'string' && value.trim() ? value.trim() : fallback;
}

export function canRedevelopSpan(span: Pick<Span, 'origin'>, coveredText: string, isAiThinking: boolean): boolean {
  return span.origin === 'ai' && !isAiThinking && coveredText.trim().split(/\s+/).filter(Boolean).length >= 3;
}

function originLine(span: Span, sources: SourceReference[]): string {
  if (span.origin === 'capture') {
    return `Captured from ${textMeta(span.meta.sourceApp, 'unknown app')}`;
  }

  if (span.origin === 'source') {
    const source = span.sourceId ? sources.find((candidate) => candidate.id === span.sourceId) : null;
    return `From ${source?.shortTitle || source?.displayName || 'source'}`;
  }

  return `Developed with ${textMeta(span.meta.model, 'unknown model')} · ${relativeDate(span.createdAt)}`;
}

function spanAt(view: EditorView, pos: number): Span | null {
  return currentSpans(view.state).find((span) => span.start <= pos && pos < span.end) ?? null;
}

function isAtomicPosition(view: EditorView, pos: number): boolean {
  return atomicRangesInView(view).some((range) => range.from <= pos && pos < range.to);
}

function button(label: string, onClick?: () => void): HTMLButtonElement {
  const element = document.createElement('button');
  element.type = 'button';
  element.className = 'cm-provenance-tooltip-button';
  element.textContent = label;
  element.disabled = !onClick;
  element.onmousedown = (event) => event.preventDefault();
  if (onClick) element.onclick = onClick;
  return element;
}

function setButtonAction(element: HTMLButtonElement, onClick?: () => void): void {
  element.disabled = !onClick;
  element.onclick = onClick ?? null;
}

function tooltipForSpan(view: EditorView, span: Span, options: ProvenanceXrayOptions): Tooltip {
  return {
    pos: span.start,
    end: span.end,
    above: true,
    create() {
      const dom = document.createElement('div');
      dom.className = 'cm-provenance-tooltip';

      const line = document.createElement('div');
      line.className = 'cm-provenance-tooltip-line';
      line.textContent = originLine(span, options.sources);
      dom.append(line);

      const actions = document.createElement('div');
      actions.className = 'cm-provenance-tooltip-actions';
      actions.append(button('dissolve', () => {
        view.dispatch({
          effects: dissolveSpans.of([span.spanId]),
          annotations: Transaction.addToHistory.of(true),
        });
        view.focus();
      }));
      if (span.origin === 'ai' && span.requestId) {
        const showExchangeButton = button('show exchange');
        actions.append(showExchangeButton);

        const coveredText = view.state.doc.sliceString(span.start, span.end);
        const redevelopButton = button('re-develop');
        actions.append(redevelopButton);

        void options.loadExchange(span.requestId).then(({ exchange }) => {
          if (!exchange) {
            showExchangeButton.textContent = 'exchange no longer stored';
            setButtonAction(showExchangeButton);
            setButtonAction(redevelopButton);
            return;
          }

          setButtonAction(showExchangeButton, () => options.onShowExchange(exchange, span));
          if (canRedevelopSpan(span, coveredText, options.isAiThinking)) {
            setButtonAction(redevelopButton, () => options.onRedevelop(span, exchange));
          }
        }).catch(() => {
          showExchangeButton.textContent = 'exchange no longer stored';
          setButtonAction(showExchangeButton);
          setButtonAction(redevelopButton);
        });
      }
      if (span.origin === 'source' && span.sourceId) {
        actions.append(button('open source →', () => options.onOpenSource(span.sourceId!)));
      }
      dom.append(actions);

      return { dom };
    },
  };
}

const provenanceXrayPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildDecorations(view);
  }

  update(update: ViewUpdate): void {
    if (
      update.docChanged ||
      update.viewportChanged ||
      update.geometryChanged ||
      currentSpans(update.startState) !== currentSpans(update.state)
    ) {
      this.decorations = buildDecorations(update.view);
    }
  }
}, {
  decorations: (value) => value.decorations,
});

export function provenanceXrayExtension(options: ProvenanceXrayOptions): Extension {
  return [
    provenanceXrayPlugin,
    hoverTooltip((view, pos) => {
      if (isAtomicPosition(view, pos)) return null;
      const span = spanAt(view, pos);
      return span ? tooltipForSpan(view, span, options) : null;
    }, { hoverTime: 180, hideOnChange: true }),
  ];
}
