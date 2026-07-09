import { syntaxTree } from '@codemirror/language';
import { RangeSetBuilder, type Extension } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, WidgetType, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';
import { bridge } from '../types';
import { isChipEligibleLink, rawLinksAreRevealedOnLine, revealRawLinksEffect } from './MarkdownConceal';

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

export function linkInfoAt(view: EditorView, pos: number): MarkdownLinkInfo | null {
  const tree = syntaxTree(view.state);
  for (const side of [-1, 1] as const) {
    for (let node: SyntaxNode | null = tree.resolveInner(pos, side); node; node = node.parent) {
      if (node.name === 'Link' && pos >= node.from && pos <= node.to) {
        return linkInfoFromNode(view, node);
      }
    }
  }
  return null;
}

/**
 * Concealed http(s) links render as atomic chips (same architecture as image
 * widgets). The caret can never enter the hidden markdown, so typing can never
 * silently edit a concealed URL. Editing happens through the chip's popover or
 * via the ⌥-click raw reveal; ⌘-click opens the URL.
 */
class LinkChipWidget extends WidgetType {
  constructor(
    private readonly label: string,
    private readonly url: string,
    private readonly onEditLink: (view: EditorView, link: MarkdownLinkInfo | null) => void
  ) {
    super();
  }

  override eq(other: LinkChipWidget): boolean {
    return other.label === this.label && other.url === this.url;
  }

  override toDOM(view: EditorView): HTMLElement {
    const chip = document.createElement('span');
    chip.className = 'cm-link-chip';
    chip.textContent = this.label;
    chip.title = this.url;

    chip.addEventListener('mousedown', (event) => {
      if (event.button !== 0) return;
      // Keep the caret where it is: no selection change, no multi-cursor.
      event.preventDefault();
      event.stopPropagation();
    });

    chip.addEventListener('click', (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();

      const pos = view.posAtDOM(chip);
      const link = linkInfoAt(view, Math.min(pos + 1, view.state.doc.length));

      if (event.altKey) {
        const lineFrom = view.state.doc.lineAt(pos).from;
        this.onEditLink(view, null);
        view.dispatch({
          selection: { anchor: pos },
          effects: revealRawLinksEffect.of(lineFrom),
        });
        return;
      }

      if (event.metaKey) {
        if (isAllowedExternalURL(this.url)) {
          bridge.send({ type: 'openExternalURL', payload: { url: this.url } });
        }
        return;
      }

      this.onEditLink(view, link);
    });

    return chip;
  }

  override ignoreEvent(): boolean {
    // The chip handles its own mouse events; everything else falls through to CM.
    return true;
  }
}

export function buildLinkChipDecorations(
  view: EditorView,
  onEditLink: (view: EditorView, link: MarkdownLinkInfo | null) => void
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);

  for (const range of view.visibleRanges) {
    tree.iterate({
      from: range.from,
      to: range.to,
      enter: (node) => {
        if (node.name !== 'Link') return;

        const lineFrom = view.state.doc.lineAt(node.from).from;
        if (rawLinksAreRevealedOnLine(view.state, lineFrom)) return;
        if (!isChipEligibleLink(view.state, node.node)) return;

        const info = linkInfoFromNode(view, node.node);
        if (!info) return;

        builder.add(
          node.from,
          node.to,
          Decoration.replace({
            widget: new LinkChipWidget(info.label, info.url, onEditLink),
          })
        );
      },
    });
  }

  return builder.finish();
}

export function linkInteractionExtension(
  onEditLink: (view: EditorView, link: MarkdownLinkInfo | null) => void
): Extension {
  const chipPlugin = ViewPlugin.fromClass(class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildLinkChipDecorations(view, onEditLink);
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.viewportChanged || update.selectionSet) {
        this.decorations = buildLinkChipDecorations(update.view, onEditLink);
      }
    }
  }, {
    decorations: (value) => value.decorations,
    provide: (plugin) => EditorView.atomicRanges.of((view) => view.plugin(plugin)?.decorations ?? Decoration.none),
  });

  return [
    chipPlugin,
    // Any cursor move or edit dismisses an open popover; chip clicks preventDefault,
    // so they never trip this.
    EditorView.updateListener.of((update) => {
      if (update.selectionSet || update.docChanged) {
        onEditLink(update.view, null);
      }
    }),
    // ⌥-click on a non-chip link (ticker-pdf citations) reveals its raw markdown;
    // chips handle their own ⌥-click in the widget.
    EditorView.domEventHandlers({
      click: (event, view) => {
        if (event.button !== 0 || !event.altKey || event.defaultPrevented) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) return false;
        const link = linkInfoAt(view, pos);
        if (!link) return false;

        event.preventDefault();
        onEditLink(view, null);
        view.dispatch({
          selection: { anchor: pos },
          effects: revealRawLinksEffect.of(link.lineFrom),
        });
        return true;
      },
    }),
  ];
}
