import type { Node as ProseNode } from 'prosemirror-model';
import { Plugin, PluginKey, type EditorState, type Transaction } from 'prosemirror-state';
import { Decoration, DecorationSet, type EditorView } from 'prosemirror-view';
import type { ConversationAnchorJSON } from '../types/models';

export interface ConversationAnchor {
  threadId: string;
  from: number;
  to: number;
  detached: boolean;
}

export interface ConversationAnchorUpdateJSON {
  threadId: string;
  anchorStart: number;
  anchorEnd: number;
  detached: boolean;
}

interface BlockRange {
  from: number;
  to: number;
  contentFrom: number;
  contentTo: number;
}

interface VisibleRange {
  from: number;
  to: number;
}

interface ConversationAnchorState {
  anchors: ConversationAnchor[];
  markerBlockFrom: Set<number>;
  visibleRanges: VisibleRange[];
  hoveredBlockFrom: number | null;
  surface: ConversationSurfaceState | null;
}

export interface ConversationSurfaceState {
  key: string;
  anchor: ConversationAnchor;
}

export interface ConversationAnchorFieldOptions {
  onCreate?: (anchor: ConversationAnchor) => void;
  onOpen?: (threadId: string) => void;
}

type AnchorMessage =
  | { kind: 'set'; anchors: ConversationAnchor[] }
  | { kind: 'visible'; ranges: VisibleRange[] }
  | { kind: 'hover'; blockFrom: number | null }
  | { kind: 'surface'; surface: ConversationSurfaceState | null };

const conversationAnchorKey = new PluginKey<ConversationAnchorState>('tickerConversationAnchors');
const pendingViewportRefreshes = new WeakSet<EditorView>();

const requestFrame = (callback: FrameRequestCallback): number => (
  typeof window.requestAnimationFrame === 'function'
    ? window.requestAnimationFrame(callback)
    : window.setTimeout(() => callback(performance.now()), 16)
);

const cancelFrame = (handle: number): void => {
  if (typeof window.cancelAnimationFrame === 'function') window.cancelAnimationFrame(handle);
  else window.clearTimeout(handle);
};

export function isConversationDecorationTransaction(tr: Transaction): boolean {
  const meta = tr.getMeta(conversationAnchorKey) as AnchorMessage | undefined;
  return !tr.docChanged && !tr.selectionSet && (
    meta?.kind === 'visible' || meta?.kind === 'hover' || meta?.kind === 'surface'
  );
}

export const setConversationAnchors = (
  tr: Transaction,
  anchors: ConversationAnchor[],
): Transaction => tr.setMeta(conversationAnchorKey, { kind: 'set', anchors });

export const setConversationVisibleRanges = (
  tr: Transaction,
  ranges: VisibleRange[],
): Transaction => tr.setMeta(conversationAnchorKey, { kind: 'visible', ranges });

export const setConversationSurface = (
  tr: Transaction,
  surface: ConversationSurfaceState | null,
): Transaction => tr.setMeta(conversationAnchorKey, { kind: 'surface', surface });

export function refreshConversationViewport(view: EditorView): void {
  if (pendingViewportRefreshes.has(view)) return;
  pendingViewportRefreshes.add(view);
  requestFrame(() => {
    try {
      applyConversationViewport(view);
    } finally {
      pendingViewportRefreshes.delete(view);
    }
  });
}

function applyConversationViewport(view: EditorView): void {
  if (view.isDestroyed) return;
  const field = conversationAnchorKey.getState(view.state);
  if (!field) return;
  const editorRect = view.dom.getBoundingClientRect();
  const viewportRect = view.dom.closest('.stream-content')?.getBoundingClientRect();
  const top = Math.max(editorRect.top, viewportRect?.top ?? 0);
  const bottom = Math.min(editorRect.bottom, viewportRect?.bottom ?? window.innerHeight);
  const fallback = textBlockAt(view.state.doc, view.state.selection.head);
  let from = editorRect.top >= top ? 0 : fallback?.from ?? 0;
  let to = editorRect.bottom <= bottom ? view.state.doc.content.size : fallback?.to ?? from;
  try {
    const left = editorRect.left + editorRect.width / 2;
    from = editorRect.top >= top ? 0 : view.posAtCoords({ left, top: top + 1 })?.pos ?? from;
    to = editorRect.bottom <= bottom
      ? view.state.doc.content.size
      : view.posAtCoords({ left, top: Math.max(top + 1, bottom - 1) })?.pos ?? to;
  } catch {
    // jsdom and a pre-layout WebView have no caret geometry; the cursor block is bounded and safe.
  }
  const next = [{ from: Math.min(from, to), to: Math.max(from, to) }];
  const current = field.visibleRanges;
  if (current.length === 1 && current[0].from === next[0].from && current[0].to === next[0].to) return;
  view.dispatch(setConversationVisibleRanges(view.state.tr, next));
}

export function conversationAnchors(state: EditorState): ConversationAnchor[] {
  return conversationAnchorKey.getState(state)?.anchors ?? [];
}

export function conversationSurface(state: EditorState): ConversationSurfaceState | null {
  return conversationAnchorKey.getState(state)?.surface ?? null;
}

/** Create the initial anchor from the complete text content of the current block. */
export function fullBlockConversationAnchor(
  doc: ProseNode,
  pos: number,
  threadId: string,
): ConversationAnchor | null {
  const block = textBlockAt(doc, pos);
  if (!block || block.contentFrom === block.contentTo) return null;
  return { threadId, from: block.contentFrom, to: block.contentTo, detached: false };
}

/** The document position immediately after the anchor's last intersecting block. */
export function conversationRenderPosition(
  doc: ProseNode,
  anchor: ConversationAnchor,
): number | null {
  if (anchor.from >= anchor.to) return null;
  return textBlockAt(doc, anchor.to - 1)?.to ?? null;
}

export function conversationAnchorText(doc: ProseNode, anchor: ConversationAnchor): string {
  return anchor.from >= anchor.to ? '' : doc.textBetween(anchor.from, anchor.to, '\n', '\n');
}

export function conversationAnchorTextForStorage(doc: ProseNode, anchor: ConversationAnchor): string {
  return conversationAnchorText(doc, anchor).slice(0, 200);
}

export function hasConversationAnchorTextDrifted(
  doc: ProseNode,
  anchor: ConversationAnchor,
  originalText: string,
): boolean {
  return anchor.from >= anchor.to || !conversationAnchorText(doc, anchor).includes(originalText);
}

export function conversationAnchorFromJSON(json: ConversationAnchorJSON): ConversationAnchor {
  const from = Number.isInteger(json.anchorStart) && (json.anchorStart as number) >= 0
    ? json.anchorStart as number
    : 0;
  const to = Number.isInteger(json.anchorEnd) && (json.anchorEnd as number) >= from
    ? json.anchorEnd as number
    : from;
  return {
    threadId: json.threadId,
    from,
    to,
    detached: to <= from,
  };
}

export function conversationAnchorToJSON(anchor: ConversationAnchor): ConversationAnchorUpdateJSON {
  return {
    threadId: anchor.threadId,
    anchorStart: anchor.from,
    anchorEnd: anchor.to,
    detached: anchor.from >= anchor.to,
  };
}

function textBlockAt(doc: ProseNode, rawPos: number): BlockRange | null {
  const pos = Math.max(0, Math.min(rawPos, doc.content.size));
  const $pos = doc.resolve(pos);
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    const node = $pos.node(depth);
    if (!node.isTextblock) continue;
    const from = $pos.before(depth);
    return {
      from,
      to: from + node.nodeSize,
      contentFrom: $pos.start(depth),
      contentTo: $pos.end(depth),
    };
  }
  return null;
}

function mapAnchor(anchor: ConversationAnchor, tr: Transaction): ConversationAnchor {
  if (!tr.docChanged) return anchor;
  let { from, to } = anchor;
  for (const step of tr.steps) {
    const map = step.getMap();
    const json = step.toJSON() as { from?: number; to?: number; structure?: boolean };
    const splitsAtTrailingEdge = json.structure === true && json.from === to && json.to === to;
    from = map.map(from, -1);
    to = map.map(to, splitsAtTrailingEdge ? -1 : 1);
  }
  return { ...anchor, from, to, detached: from >= to };
}

function validAnchors(anchors: ConversationAnchor[], doc: ProseNode): ConversationAnchor[] {
  return anchors.filter((anchor) => (
    anchor.from >= 0
    && anchor.to <= doc.content.size
    && anchor.from <= anchor.to
  )).map((anchor) => ({ ...anchor, detached: anchor.from >= anchor.to }));
}

function mapRange(range: VisibleRange, tr: Transaction): VisibleRange {
  return {
    from: tr.mapping.map(range.from, -1),
    to: tr.mapping.map(range.to, 1),
  };
}

export interface ConversationDecorationTarget extends BlockRange {
  left: boolean;
  right: boolean;
}

export function conversationMarkerBlockPositions(
  doc: ProseNode,
  anchors: ConversationAnchor[],
): Set<number> {
  const positions = new Set<number>();
  for (const anchor of anchors) {
    const marker = conversationRenderPosition(doc, anchor);
    const block = marker === null ? null : textBlockAt(doc, marker - 1);
    if (block) positions.add(block.from);
  }
  return positions;
}

/** Only walks visible document ranges; anchor endpoints are resolved directly. */
export function conversationDecorationTargets(
  doc: ProseNode,
  markerBlockFrom: ReadonlySet<number>,
  visibleRanges: VisibleRange[],
  activeBlockFrom: number | null,
): ConversationDecorationTarget[] {
  const visibleBlocks = new Map<number, ConversationDecorationTarget>();
  for (const range of visibleRanges) {
    const from = Math.max(0, Math.min(range.from, doc.content.size));
    const to = Math.max(from, Math.min(range.to, doc.content.size));
    if (from === to) continue;
    doc.nodesBetween(from, to, (node, pos) => {
      if (!node.isTextblock) return true;
      visibleBlocks.set(pos, {
        from: pos,
        to: pos + node.nodeSize,
        contentFrom: pos + 1,
        contentTo: pos + node.nodeSize - 1,
        left: pos === activeBlockFrom,
        right: false,
      });
      return false;
    });
  }

  for (const [pos, target] of visibleBlocks) {
    if (markerBlockFrom.has(pos)) target.right = true;
  }
  return [...visibleBlocks.values()].filter((target) => target.left || target.right);
}

export function conversationAnchorField(
  options: ConversationAnchorFieldOptions = {},
): Plugin<ConversationAnchorState> {
  let hoverFrame: number | null = null;
  let pendingHover: { view: EditorView; left: number; top: number } | { view: EditorView } | null = null;
  const queueHover = (view: EditorView, point?: { left: number; top: number }): void => {
    pendingHover = point ? { view, ...point } : { view };
    if (hoverFrame !== null) return;
    hoverFrame = requestFrame(() => {
      const pending = pendingHover;
      pendingHover = null;
      hoverFrame = null;
      if (!pending) return;
      const found = 'left' in pending
        ? pending.view.posAtCoords({ left: pending.left, top: pending.top })
        : null;
      const blockFrom = found ? textBlockAt(pending.view.state.doc, found.pos)?.from ?? null : null;
      if (blockFrom !== conversationAnchorKey.getState(pending.view.state)?.hoveredBlockFrom) {
        pending.view.dispatch(pending.view.state.tr.setMeta(conversationAnchorKey, { kind: 'hover', blockFrom }));
      }
    });
  };

  return new Plugin<ConversationAnchorState>({
    key: conversationAnchorKey,
    state: {
      init: () => ({
        anchors: [],
        markerBlockFrom: new Set(),
        visibleRanges: [],
        hoveredBlockFrom: null,
        surface: null,
      }),
      apply(tr, current, _old, next) {
        const anchors = current.anchors.map((anchor) => mapAnchor(anchor, tr));
        const mapped: ConversationAnchorState = {
          anchors,
          markerBlockFrom: tr.docChanged
            ? conversationMarkerBlockPositions(next.doc, anchors)
            : current.markerBlockFrom,
          visibleRanges: tr.docChanged
            ? current.visibleRanges.map((range) => mapRange(range, tr))
            : current.visibleRanges,
          hoveredBlockFrom: current.hoveredBlockFrom === null
            ? null
            : tr.mapping.map(current.hoveredBlockFrom, -1),
          surface: current.surface === null
            ? null
            : { ...current.surface, anchor: mapAnchor(current.surface.anchor, tr) },
        };
        const meta = tr.getMeta(conversationAnchorKey) as AnchorMessage | undefined;
        if (!meta) return mapped;
        if (meta.kind === 'set') {
          const valid = validAnchors(meta.anchors, next.doc);
          return {
            ...mapped,
            anchors: valid,
            markerBlockFrom: conversationMarkerBlockPositions(next.doc, valid),
          };
        }
        if (meta.kind === 'visible') return { ...mapped, visibleRanges: meta.ranges };
        if (meta.kind === 'hover') return { ...mapped, hoveredBlockFrom: meta.blockFrom };
        return { ...mapped, surface: meta.surface };
      },
    },
    props: {
      decorations(state) {
        const field = conversationAnchorKey.getState(state);
        if (!field) return null;
        const cursorBlock = textBlockAt(state.doc, state.selection.head)?.from ?? null;
        const targets = conversationDecorationTargets(
          state.doc,
          field.markerBlockFrom,
          field.visibleRanges,
          field.hoveredBlockFrom ?? cursorBlock,
        );
        const decorations = targets.map((target) => Decoration.node(
          target.from,
          target.to,
          { class: [target.left && 'conversation-block-active', target.right && 'conversation-block-anchored'].filter(Boolean).join(' ') },
        ));
        const surface = field.surface;
        const position = surface && conversationRenderPosition(state.doc, surface.anchor);
        if (surface && position !== null) {
          decorations.push(Decoration.widget(position, () => {
            const host = document.createElement('div');
            host.className = 'conversation-widget-host';
            host.contentEditable = 'false';
            host.dataset.conversationWidget = surface.key;
            return host;
          }, {
            key: surface.key,
            side: 1,
            stopEvent: () => true,
            ignoreSelection: true,
          }));
        }
        return DecorationSet.create(state.doc, decorations);
      },
      handleDOMEvents: {
        mousemove(view, event) {
          queueHover(view, { left: event.clientX, top: event.clientY });
          return false;
        },
        mouseleave(view) {
          queueHover(view);
          return false;
        },
        click(view, event) {
          const target = event.target instanceof Element
            ? event.target.closest<HTMLElement>('.conversation-block-active, .conversation-block-anchored')
            : null;
          if (!target || !view.dom.contains(target)) return false;
          const rect = target.getBoundingClientRect();
          let block: BlockRange | null = null;
          try {
            block = textBlockAt(view.state.doc, view.posAtDOM(target, 0));
          } catch {
            return false;
          }
          if (!block) return false;
          if (event.clientX < rect.left && target.classList.contains('conversation-block-active')) {
            const anchor = fullBlockConversationAnchor(view.state.doc, block.contentFrom, '');
            if (!anchor) return false;
            event.preventDefault();
            options.onCreate?.(anchor);
            return true;
          }
          if (event.clientX > rect.right && target.classList.contains('conversation-block-anchored')) {
            const field = conversationAnchorKey.getState(view.state);
            const anchor = field?.anchors.find((candidate) => {
              const position = conversationRenderPosition(view.state.doc, candidate);
              return position !== null && textBlockAt(view.state.doc, position - 1)?.from === block?.from;
            });
            if (!anchor) return false;
            event.preventDefault();
            options.onOpen?.(anchor.threadId);
            return true;
          }
          return false;
        },
      },
    },
    view: () => ({
      destroy() {
        if (hoverFrame !== null) cancelFrame(hoverFrame);
        hoverFrame = null;
        pendingHover = null;
      },
    }),
  });
}
