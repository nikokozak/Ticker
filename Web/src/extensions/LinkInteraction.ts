import { syntaxTree } from '@codemirror/language';
import { type Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';
import { bridge } from '../types';
import { rawLinksAreRevealedOnLine, revealRawLinksEffect } from './MarkdownConceal';

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

function linkInfoAt(view: EditorView, pos: number): MarkdownLinkInfo | null {
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(pos, -1); node; node = node.parent) {
    if (node.name === 'Link') return linkInfoFromNode(view, node);
  }
  return null;
}

function sameLink(left: MarkdownLinkInfo | null, right: MarkdownLinkInfo | null): boolean {
  return Boolean(left && right && left.from === right.from && left.to === right.to);
}

export function linkInteractionExtension(
  onEditLink: (view: EditorView, link: MarkdownLinkInfo | null) => void
): Extension {
  let clickStartedInsideLink: MarkdownLinkInfo | null = null;
  let suppressSelectionPopover = false;

  return [
    EditorView.updateListener.of((update) => {
      if (!update.selectionSet && !update.docChanged) return;

      const selection = update.state.selection.main;
      if (!selection.empty) {
        onEditLink(update.view, null);
        return;
      }

      const link = linkInfoAt(update.view, selection.head);
      if (!link || rawLinksAreRevealedOnLine(update.state, link.lineFrom) || suppressSelectionPopover) {
        onEditLink(update.view, null);
        return;
      }

      onEditLink(update.view, link);
    }),
    EditorView.domEventHandlers({
      mousedown: (event, view) => {
        clickStartedInsideLink = null;
        suppressSelectionPopover = false;
        if (event.button !== 0 || event.defaultPrevented) return false;

        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) return false;

        const clickedLink = linkInfoAt(view, pos);
        const selection = view.state.selection.main;
        const currentLink = selection.empty ? linkInfoAt(view, selection.head) : null;
        clickStartedInsideLink = sameLink(clickedLink, currentLink) ? clickedLink : null;
        suppressSelectionPopover = Boolean(clickedLink && !clickStartedInsideLink);
        return false;
      },
      click: (event, view) => {
        if (event.button !== 0 || event.defaultPrevented) return false;

        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        const link = pos == null ? null : linkInfoAt(view, pos);
        if (!link) {
          suppressSelectionPopover = false;
          onEditLink(view, null);
          return false;
        }

        if (event.altKey) {
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

        if (link.url.startsWith('ticker-pdf://')) {
          suppressSelectionPopover = false;
          return false;
        }

        if (sameLink(clickStartedInsideLink, link)) {
          event.preventDefault();
          event.stopPropagation();
          suppressSelectionPopover = false;
          onEditLink(view, link);
          return true;
        }

        suppressSelectionPopover = false;
        if (!isAllowedExternalURL(link.url)) return false;

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
