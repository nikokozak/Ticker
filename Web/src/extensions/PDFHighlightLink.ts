import { syntaxTree } from '@codemirror/language';
import { RangeSetBuilder, type Extension } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';
import { bridge } from '../types';

export interface TickerPDFDestination {
  sourceId: string;
  highlightId?: string;
  page?: number;
}

export function parseTickerPDFURL(rawURL: string): TickerPDFDestination | null {
  if (!rawURL.startsWith('ticker-pdf://')) return null;

  try {
    const url = new URL(rawURL);
    const sourceId = decodeURIComponent(url.hostname || url.pathname.replace(/^\/+/, ''));
    if (!sourceId) return null;

    const highlight = url.searchParams.get('highlight')?.trim() || undefined;
    const pageValue = url.searchParams.get('page');
    const pageNumber = pageValue ? Number(pageValue) : NaN;
    const page = Number.isInteger(pageNumber) && pageNumber > 0 ? pageNumber : undefined;

    return {
      sourceId,
      highlightId: highlight,
      page,
    };
  } catch {
    return null;
  }
}

function urlForLinkNode(view: EditorView, linkNode: SyntaxNode): string | null {
  const cursor = linkNode.cursor();
  if (!cursor.firstChild()) return null;

  do {
    if (cursor.name === 'URL') {
      return view.state.doc.sliceString(cursor.from, cursor.to);
    }
  } while (cursor.nextSibling());

  return null;
}

function linkNodeAt(view: EditorView, pos: number): SyntaxNode | null {
  for (let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(pos, -1); node; node = node.parent) {
    if (node.name === 'Link') return node;
  }
  return null;
}

function destinationAt(view: EditorView, pos: number): TickerPDFDestination | null {
  const linkNode = linkNodeAt(view, pos);
  if (!linkNode) return null;

  const rawURL = urlForLinkNode(view, linkNode);
  return rawURL ? parseTickerPDFURL(rawURL) : null;
}

function buildTickerPDFLinkDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);

  for (const range of view.visibleRanges) {
    tree.iterate({
      from: range.from,
      to: range.to,
      enter: (node) => {
        if (node.name !== 'Link') return;
        const rawURL = urlForLinkNode(view, node.node);
        if (!rawURL?.startsWith('ticker-pdf://')) return;
        builder.add(node.from, node.to, Decoration.mark({ class: 'cm-ticker-pdf-link' }));
      },
    });
  }

  return builder.finish();
}

const tickerPDFLinkDecorationPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildTickerPDFLinkDecorations(view);
  }

  update(update: ViewUpdate): void {
    if (update.docChanged || update.viewportChanged) {
      this.decorations = buildTickerPDFLinkDecorations(update.view);
    }
  }
}, {
  decorations: (value) => value.decorations,
});

const tickerPDFLinkTheme = EditorView.theme({
  '.cm-ticker-pdf-link': {
    color: 'var(--accent)',
    cursor: 'pointer',
  },
});

export function tickerPDFLinkExtension(streamId: string): Extension {
  return [
    tickerPDFLinkDecorationPlugin,
    tickerPDFLinkTheme,
    EditorView.domEventHandlers({
      click: (event, view) => {
        if (event.button !== 0 || event.defaultPrevented) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) return false;

        const destination = destinationAt(view, pos);
        if (!destination) return false;

        event.preventDefault();
        event.stopPropagation();
        bridge.send({
          type: 'openPdfDestination',
          payload: {
            streamId,
            sourceId: destination.sourceId,
            highlightId: destination.highlightId,
            page: destination.page,
          },
        });
        return true;
      },
    }),
  ];
}
