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
}

type AnchorMessage =
  | { kind: 'set'; anchors: ConversationAnchor[] }
  | { kind: 'visible'; ranges: VisibleRange[] }
  | { kind: 'hover'; blockFrom: number | null };

const conversationAnchorKey = new PluginKey<ConversationAnchorState>('tickerConversationAnchors');

export const setConversationAnchors = (
  tr: Transaction,
  anchors: ConversationAnchor[],
): Transaction => tr.setMeta(conversationAnchorKey, { kind: 'set', anchors });

export const setConversationVisibleRanges = (
  tr: Transaction,
  ranges: VisibleRange[],
): Transaction => tr.setMeta(conversationAnchorKey, { kind: 'visible', ranges });

export function refreshConversationViewport(view: EditorView): void {
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
  if (anchor.detached || anchor.from >= anchor.to) return null;
  return textBlockAt(doc, anchor.to - 1)?.to ?? null;
}

export function conversationAnchorText(doc: ProseNode, anchor: ConversationAnchor): string {
  return anchor.detached ? '' : doc.textBetween(anchor.from, anchor.to, '\n', '\n');
}

export function conversationAnchorTextForStorage(doc: ProseNode, anchor: ConversationAnchor): string {
  return [...conversationAnchorText(doc, anchor)].slice(0, 200).join('');
}

export function hasConversationAnchorTextDrifted(
  doc: ProseNode,
  anchor: ConversationAnchor,
  originalText: string,
): boolean {
  return anchor.detached || !conversationAnchorText(doc, anchor).includes(originalText);
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
    detached: json.detached || from < 0 || to <= from,
  };
}

export function conversationAnchorToJSON(anchor: ConversationAnchor): ConversationAnchorUpdateJSON {
  return {
    threadId: anchor.threadId,
    anchorStart: anchor.from,
    anchorEnd: anchor.to,
    detached: anchor.detached,
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
  if (!tr.docChanged || anchor.detached) return anchor;
  let { from, to } = anchor;
  for (const step of tr.steps) {
    const map = step.getMap();
    from = map.map(from, -1);
    to = map.map(to, 1);
  }
  return { ...anchor, from, to, detached: to <= from };
}

function validAnchors(anchors: ConversationAnchor[], doc: ProseNode): ConversationAnchor[] {
  return anchors.filter((anchor) => (
    anchor.from >= 0
    && anchor.to <= doc.content.size
    && (anchor.detached ? anchor.from <= anchor.to : anchor.from < anchor.to)
  ));
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

export function conversationAnchorField(): Plugin<ConversationAnchorState> {
  return new Plugin<ConversationAnchorState>({
    key: conversationAnchorKey,
    state: {
      init: () => ({ anchors: [], markerBlockFrom: new Set(), visibleRanges: [], hoveredBlockFrom: null }),
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
        return { ...mapped, hoveredBlockFrom: meta.blockFrom };
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
        return DecorationSet.create(state.doc, targets.map((target) => Decoration.node(
          target.from,
          target.to,
          { class: [target.left && 'conversation-block-active', target.right && 'conversation-block-anchored'].filter(Boolean).join(' ') },
        )));
      },
      handleDOMEvents: {
        mousemove(view, event) {
          const found = view.posAtCoords({ left: event.clientX, top: event.clientY });
          const blockFrom = found ? textBlockAt(view.state.doc, found.pos)?.from ?? null : null;
          if (blockFrom !== conversationAnchorKey.getState(view.state)?.hoveredBlockFrom) {
            view.dispatch(view.state.tr.setMeta(conversationAnchorKey, { kind: 'hover', blockFrom }));
          }
          return false;
        },
        mouseleave(view) {
          if (conversationAnchorKey.getState(view.state)?.hoveredBlockFrom !== null) {
            view.dispatch(view.state.tr.setMeta(conversationAnchorKey, { kind: 'hover', blockFrom: null }));
          }
          return false;
        },
        click() {
          // ponytail: visual no-op for C2; C3 replaces this with open/create routing.
          return false;
        },
      },
    },
  });
}
