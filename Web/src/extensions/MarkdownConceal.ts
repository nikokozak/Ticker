import { EditorState, StateEffect, StateField, type Extension, type Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

const MARK_NODE_NAMES = new Set(['EmphasisMark', 'StrongEmphasisMark', 'CodeMark', 'CodeInfo']);
const LINK_CONCEAL_NODE_NAMES = new Set(['LinkMark', 'URL', 'LinkTitle']);
const INITIAL_MARKDOWN_PARSE_TIMEOUT_MS = 20;

export const revealRawLinksEffect = StateEffect.define<number | null>();

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

function selectionIntersectsLine(state: EditorState, lineFrom: number, lineTo: number): boolean {
  const lineEnd = lineTo < state.doc.length ? lineTo + 1 : lineTo;

  return state.selection.ranges.some((range) => {
    const from = Math.min(range.from, range.to);
    const to = Math.max(range.from, range.to);

    if (from === to) {
      return state.doc.lineAt(from).from === lineFrom;
    }

    return lineFrom < to && lineEnd > from;
  });
}

const revealRawLinksField = StateField.define<number | null>({
  create: () => null,
  update(value, transaction) {
    let next = value;
    if (next !== null && transaction.docChanged) {
      next = transaction.changes.mapPos(next);
    }

    for (const effect of transaction.effects) {
      if (effect.is(revealRawLinksEffect)) {
        next = effect.value;
      }
    }

    if (next !== null && (transaction.selection || transaction.docChanged)) {
      const line = transaction.state.doc.lineAt(Math.min(next, transaction.state.doc.length));
      if (!selectionIntersectsLine(transaction.state, line.from, line.to)) {
        next = null;
      } else {
        next = line.from;
      }
    }

    return next;
  },
});

export function rawLinksAreRevealedOnLine(state: EditorState, lineFrom: number): boolean {
  return state.field(revealRawLinksField, false) === lineFrom;
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
  const codeblockLineStarts = new Set<number>();
  const tree = markdownTreeForDecorations(view, ensureInitialParse);
  const rawLinksLineFrom = view.state.field(revealRawLinksField, false);

  for (const visibleRange of view.visibleRanges) {
    tree.iterate({
      from: visibleRange.from,
      to: visibleRange.to,
      enter: (node) => {
        const line = view.state.doc.lineAt(node.from);
        const isLinkConcealNode = LINK_CONCEAL_NODE_NAMES.has(node.name) && node.matchContext(['Link']);
        if (isLineSelected(view, line.from, line.to) && (!isLinkConcealNode || rawLinksLineFrom === line.from)) {
          return;
        }

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

        if (node.name === 'FencedCode') {
          const from = Math.max(node.from, visibleRange.from);
          const to = Math.min(node.to, visibleRange.to);
          let line = view.state.doc.lineAt(from);

          while (line.from < to) {
            if (!codeblockLineStarts.has(line.from)) {
              codeblockLineStarts.add(line.from);
              decorations.push(Decoration.line({ class: 'cm-codeblock-line' }).range(line.from));
            }
            if (line.to >= to || line.number >= view.state.doc.lines) break;
            line = view.state.doc.line(line.number + 1);
          }
          return;
        }

        if (MARK_NODE_NAMES.has(node.name)) {
          const decoration = concealRange(node.from, node.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (isLinkConcealNode) {
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
    const rawLinksChanged = update.startState.field(revealRawLinksField, false) !==
      update.state.field(revealRawLinksField, false);
    if (update.docChanged || update.viewportChanged || update.selectionSet || rawLinksChanged) {
      this.decorations = buildMarkdownConcealDecorations(update.view);
    }
  }
}, {
  decorations: (value) => value.decorations,
});

export const markdownConcealExtension: Extension = [revealRawLinksField, markdownConcealPlugin];
