import { syntaxTree } from '@codemirror/language';
import { RangeSetBuilder, type Extension } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';
import { bridge } from '../types';
import { rawLinksAreRevealedOnLine, revealRawLinksEffect } from './MarkdownConceal';

const RENDERED_LINK_CLASS = 'cm-rendered-link';
const RENDERED_LINK_SELECTOR = `.${RENDERED_LINK_CLASS}`;
const LINK_X_TOLERANCE_PX = 4;

export const LINK_NAVIGATION_MAX_POINTER_MOVEMENT_PX = 5;

export interface MarkdownLinkInfo {
  from: number;
  to: number;
  labelFrom: number;
  labelTo: number;
  label: string;
  url: string;
  lineFrom: number;
}

export interface LinkEditRange {
  from: number;
  to: number;
}

export interface LinkEditChange extends LinkEditRange {
  insert: string;
}

export function isAllowedExternalURL(rawURL: string): boolean {
  if (!/^https?:\/\//i.test(rawURL)) return false;

  try {
    const url = new URL(rawURL);
    return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname);
  } catch {
    return false;
  }
}

export function buildLinkEditChange(oldRange: LinkEditRange, label: string, url: string): LinkEditChange | null {
  const nextLabel = label.trim().replace(/\\/g, '\\\\').replace(/\]/g, '\\]');
  const nextURL = url.trim();
  if (!nextLabel || !nextURL) return null;
  return {
    from: oldRange.from,
    to: oldRange.to,
    insert: `[${nextLabel}](${nextURL})`,
  };
}

interface Point {
  x: number;
  y: number;
}

export function pointerMovementAllowsNavigation(start: Point | null, end: Point): boolean {
  if (!start) return false;
  return Math.hypot(end.x - start.x, end.y - start.y) < LINK_NAVIGATION_MAX_POINTER_MOVEMENT_PX;
}

export function positionTouchesLinkRange(pos: number, link: Pick<MarkdownLinkInfo, 'from' | 'to'>): boolean {
  return pos >= link.from && pos <= link.to;
}

export function xWithinLinkExtent(x: number, left: number, right: number, tolerance = LINK_X_TOLERANCE_PX): boolean {
  return x >= Math.min(left, right) - tolerance && x <= Math.max(left, right) + tolerance;
}

function linkInfoFromNode(view: EditorView, linkNode: SyntaxNode): MarkdownLinkInfo | null {
  const marks: Array<{ from: number; to: number }> = [];
  let urlFrom = -1;
  let urlTo = -1;
  const cursor = linkNode.cursor();
  if (!cursor.firstChild()) return null;

  do {
    if (cursor.name === 'LinkMark') {
      marks.push({ from: cursor.from, to: cursor.to });
    } else if (cursor.name === 'URL') {
      urlFrom = cursor.from;
      urlTo = cursor.to;
    }
  } while (cursor.nextSibling());

  if (marks.length < 2 || urlFrom < 0 || urlTo <= urlFrom) return null;

  const labelFrom = marks[0].to;
  const labelTo = marks[1].from;
  const line = view.state.doc.lineAt(linkNode.from);
  return {
    from: linkNode.from,
    to: linkNode.to,
    labelFrom,
    labelTo,
    label: view.state.doc.sliceString(labelFrom, labelTo),
    url: view.state.doc.sliceString(urlFrom, urlTo),
    lineFrom: line.from,
  };
}

function linkNodeAt(view: EditorView, pos: number): SyntaxNode | null {
  const tree = syntaxTree(view.state);
  for (const side of [-1, 1] as const) {
    for (let node: SyntaxNode | null = tree.resolveInner(pos, side); node; node = node.parent) {
      if (node.name === 'Link' && positionTouchesLinkRange(pos, node)) return node;
    }
  }
  return null;
}

export function linkInfoAt(view: EditorView, pos: number): MarkdownLinkInfo | null {
  const node = linkNodeAt(view, pos);
  return node ? linkInfoFromNode(view, node) : null;
}

function linkKey(link: MarkdownLinkInfo): string {
  return `${link.from}:${link.to}`;
}

function hasRenderedLinkTarget(target: EventTarget | null): boolean {
  if (typeof Element !== 'undefined' && target instanceof Element) {
    return Boolean(target.closest(RENDERED_LINK_SELECTOR));
  }

  if (typeof Node !== 'undefined' && target instanceof Node) {
    return Boolean(target.parentElement?.closest(RENDERED_LINK_SELECTOR));
  }

  return false;
}

function linkHorizontalHitTest(view: EditorView, link: MarkdownLinkInfo, pos: number, clientX: number): boolean {
  if (!view.coordsAtPos(pos)) return false;

  const line = view.state.doc.lineAt(Math.min(pos, view.state.doc.length));
  const startRect = view.coordsAtPos(Math.max(link.from, line.from));
  const endRect = view.coordsAtPos(Math.min(link.to, line.to));
  if (!startRect || !endRect) return false;

  return xWithinLinkExtent(clientX, startRect.left, endRect.right);
}

function buildRenderedLinkDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);

  for (const range of view.visibleRanges) {
    tree.iterate({
      from: range.from,
      to: range.to,
      enter: (node) => {
        if (node.name === 'Link') {
          builder.add(node.from, node.to, Decoration.mark({ class: RENDERED_LINK_CLASS }));
        }
      },
    });
  }

  return builder.finish();
}

export function linkInteractionExtension(
  onEditLink: (view: EditorView, link: MarkdownLinkInfo | null) => void
): Extension {
  let pointerStart: Point | null = null;
  let suppressSelectionPopover = false;
  let activePopoverLinkKey: string | null = null;

  return [
    ViewPlugin.fromClass(class {
      decorations: DecorationSet;

      constructor(view: EditorView) {
        this.decorations = buildRenderedLinkDecorations(view);
      }

      update(update: ViewUpdate): void {
        if (update.docChanged || update.viewportChanged) {
          this.decorations = buildRenderedLinkDecorations(update.view);
        }
      }
    }, {
      decorations: (value) => value.decorations,
    }),
    ViewPlugin.fromClass(class {
      private readonly window: Window;
      private readonly onKeyDown = (event: KeyboardEvent) => {
        if (event.key === 'Meta') this.view.dom.classList.add('cm-link-meta-down');
      };
      private readonly onKeyUp = (event: KeyboardEvent) => {
        if (event.key === 'Meta') this.view.dom.classList.remove('cm-link-meta-down');
      };
      private readonly onBlur = () => {
        this.view.dom.classList.remove('cm-link-meta-down');
      };

      constructor(private readonly view: EditorView) {
        this.window = view.dom.ownerDocument.defaultView ?? window;
        this.window.addEventListener('keydown', this.onKeyDown);
        this.window.addEventListener('keyup', this.onKeyUp);
        this.window.addEventListener('blur', this.onBlur);
      }

      destroy(): void {
        this.window.removeEventListener('keydown', this.onKeyDown);
        this.window.removeEventListener('keyup', this.onKeyUp);
        this.window.removeEventListener('blur', this.onBlur);
        this.view.dom.classList.remove('cm-link-meta-down');
      }
    }),
    EditorView.theme({
      '&.cm-link-meta-down .cm-rendered-link': {
        cursor: 'pointer',
      },
    }),
    EditorView.updateListener.of((update) => {
      if (!update.selectionSet && !update.docChanged) return;

      const selection = update.state.selection.main;
      if (!selection.empty) {
        activePopoverLinkKey = null;
        onEditLink(update.view, null);
        return;
      }

      const link = linkInfoAt(update.view, selection.head);
      if (!link || rawLinksAreRevealedOnLine(update.state, link.lineFrom) || suppressSelectionPopover) {
        activePopoverLinkKey = null;
        onEditLink(update.view, null);
        return;
      }

      const nextKey = linkKey(link);
      if (activePopoverLinkKey === nextKey) return;
      activePopoverLinkKey = nextKey;
      onEditLink(update.view, link);
    }),
    EditorView.domEventHandlers({
      mousedown: (event) => {
        suppressSelectionPopover = false;
        if (event.button !== 0 || event.defaultPrevented) return false;
        pointerStart = { x: event.clientX, y: event.clientY };
        return false;
      },
      click: (event, view) => {
        if (event.button !== 0 || event.defaultPrevented) return false;

        if (event.altKey) {
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          const link = pos == null ? null : linkInfoAt(view, pos);
          if (!link) {
            suppressSelectionPopover = false;
            onEditLink(view, null);
            return false;
          }

          event.preventDefault();
          event.stopPropagation();
          suppressSelectionPopover = true;
          onEditLink(view, null);
          view.dispatch({
            selection: { anchor: Math.min(pos ?? link.from, view.state.doc.length) },
            effects: revealRawLinksEffect.of(link.lineFrom),
          });
          window.setTimeout(() => {
            suppressSelectionPopover = false;
          }, 0);
          return true;
        }

        if (!event.metaKey) return false;

        if (!pointerMovementAllowsNavigation(pointerStart, { x: event.clientX, y: event.clientY })) {
          suppressSelectionPopover = false;
          return false;
        }

        if (!hasRenderedLinkTarget(event.target)) {
          suppressSelectionPopover = false;
          return false;
        }

        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) {
          suppressSelectionPopover = false;
          return false;
        }

        const link = linkInfoAt(view, pos);
        if (!link || link.url.startsWith('ticker-pdf://') || !positionTouchesLinkRange(pos, link)) {
          suppressSelectionPopover = false;
          return false;
        }

        suppressSelectionPopover = false;
        if (!isAllowedExternalURL(link.url) || !linkHorizontalHitTest(view, link, pos, event.clientX)) return false;

        event.preventDefault();
        event.stopPropagation();
        bridge.send({
          type: 'openExternalURL',
          payload: { url: link.url },
        });
        return true;
      },
    }),
  ];
}
