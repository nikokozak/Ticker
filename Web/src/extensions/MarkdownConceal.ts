import { type Extension, type Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

const MARK_NODE_NAMES = new Set(['EmphasisMark', 'StrongEmphasisMark', 'CodeMark', 'CodeInfo']);
const LINK_CONCEAL_NODE_NAMES = new Set(['LinkMark', 'URL', 'LinkTitle']);
const INITIAL_MARKDOWN_PARSE_TIMEOUT_MS = 20;

function isLineSelected(view: EditorView, lineFrom: number, lineTo: number): boolean {
  const doc = view.state.doc;
  const lineEnd = lineTo < doc.length ? lineTo + 1 : lineTo;

  return view.state.selection.ranges.some((range) => {
    const from = Math.min(range.from, range.to);
    const to = Math.max(range.from, range.to);

    if (from === to) {
      const cursorLine = doc.lineAt(from);
      return cursorLine.from === lineFrom;
    }

    return lineFrom < to && lineEnd > from;
  });
}

function rangeWithFollowingSpace(view: EditorView, from: number, to: number): { from: number; to: number } {
  if (to >= view.state.doc.length) return { from, to };
  const nextCharacter = view.state.doc.sliceString(to, to + 1);
  return nextCharacter === ' ' ? { from, to: to + 1 } : { from, to };
}

function rangeWithFollowingSpaces(view: EditorView, from: number, to: number): { from: number; to: number } {
  let end = to;
  while (end < view.state.doc.length && view.state.doc.sliceString(end, end + 1) === ' ') {
    end += 1;
  }

  return { from, to: end };
}

function concealRange(from: number, to: number): Range<Decoration> | null {
  if (from >= to) return null;
  return Decoration.replace({}).range(from, to);
}

function visibleRangeEnd(view: EditorView): number {
  return view.visibleRanges.reduce((end, range) => Math.max(end, range.to), view.viewport.to);
}

function markdownTreeForDecorations(view: EditorView, ensureInitialParse: boolean) {
  if (!ensureInitialParse) return syntaxTree(view.state);
  return ensureSyntaxTree(view.state, visibleRangeEnd(view), INITIAL_MARKDOWN_PARSE_TIMEOUT_MS) ?? syntaxTree(view.state);
}

function buildMarkdownConcealDecorations(view: EditorView, ensureInitialParse = false): DecorationSet {
  const decorations: Array<Range<Decoration>> = [];
  const blockquoteLineStarts = new Set<number>();
  const tree = markdownTreeForDecorations(view, ensureInitialParse);

  for (const visibleRange of view.visibleRanges) {
    tree.iterate({
      from: visibleRange.from,
      to: visibleRange.to,
      enter: (node) => {
        const line = view.state.doc.lineAt(node.from);
        if (isLineSelected(view, line.from, line.to)) return;

        if (node.name === 'HeaderMark') {
          const range = rangeWithFollowingSpace(view, node.from, node.to);
          const decoration = concealRange(range.from, range.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (node.name === 'QuoteMark') {
          const range = rangeWithFollowingSpace(view, node.from, node.to);
          const decoration = concealRange(range.from, range.to);
          if (decoration) decorations.push(decoration);

          if (!blockquoteLineStarts.has(line.from)) {
            blockquoteLineStarts.add(line.from);
            decorations.push(Decoration.line({ class: 'cm-blockquote-line' }).range(line.from));
          }
          return;
        }

        if (MARK_NODE_NAMES.has(node.name)) {
          const decoration = concealRange(node.from, node.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (LINK_CONCEAL_NODE_NAMES.has(node.name) && node.matchContext(['Link'])) {
          const range = node.name === 'URL' ? rangeWithFollowingSpaces(view, node.from, node.to) : { from: node.from, to: node.to };
          const decoration = concealRange(range.from, range.to);
          if (decoration) decorations.push(decoration);
        }
      },
    });
  }

  return Decoration.set(decorations, true);
}

const markdownConcealPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildMarkdownConcealDecorations(view, true);
  }

  update(update: ViewUpdate): void {
    if (update.docChanged || update.viewportChanged || update.selectionSet) {
      this.decorations = buildMarkdownConcealDecorations(update.view);
    }
  }
}, {
  decorations: (value) => value.decorations,
});

export const markdownConcealExtension: Extension = markdownConcealPlugin;
