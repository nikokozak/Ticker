import { EditorState, StateEffect, StateField, type Extension, type Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode, SyntaxNodeRef } from '@lezer/common';

const MARK_NODE_NAMES = new Set(['EmphasisMark', 'StrongEmphasisMark', 'CodeMark', 'CodeInfo']);
const LINK_CONCEAL_NODE_NAMES = new Set(['LinkMark', 'URL', 'LinkTitle']);
const INITIAL_MARKDOWN_PARSE_TIMEOUT_MS = 20;

export const revealRawLinksEffect = StateEffect.define<number | null>();
const setConcealMouseDownEffect = StateEffect.define<boolean>();

/** True when an http(s) link that the chip layer replaces wholesale — conceal leaves it alone. */
export function isChipEligibleLink(state: EditorState, linkNode: SyntaxNode): boolean {
  const urlNode = linkNode.getChild('URL');
  if (!urlNode) return false;
  const url = state.doc.sliceString(urlNode.from, urlNode.to);
  return /^https?:\/\//i.test(url);
}

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

const concealMouseDownField = StateField.define<boolean>({
  create: () => false,
  update(value, transaction) {
    let next = value;
    for (const effect of transaction.effects) {
      if (effect.is(setConcealMouseDownEffect)) next = effect.value;
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

export interface MarkdownConcealBuildOptions {
  ensureInitialParse?: boolean;
  /**
   * When false (mouse held down), selection-based reveal is disabled: everything
   * stays concealed so layout cannot shift under an in-progress drag. The set is
   * still rebuilt on every relevant update — freezing the DecorationSet itself
   * desyncs viewport coverage (regions scrolled into view would render raw).
   */
  revealForSelection?: boolean;
}

export function buildMarkdownConcealDecorations(
  view: EditorView,
  options: MarkdownConcealBuildOptions = {}
): DecorationSet {
  const { ensureInitialParse = false, revealForSelection = true } = options;
  const decorations: Array<Range<Decoration>> = [];
  const blockquoteLineStarts = new Set<number>();
  const codeblockLineStarts = new Set<number>();
  const tree = markdownTreeForDecorations(view, ensureInitialParse);
  const rawLinksLineFrom = view.state.field(revealRawLinksField, false);
  let activeChipLink: { from: number; to: number } | null = null;

  for (const visibleRange of view.visibleRanges) {
    tree.iterate({
      from: visibleRange.from,
      to: visibleRange.to,
      enter: (node: SyntaxNodeRef) => {
        if (node.name === 'Link') {
          const line = view.state.doc.lineAt(node.from);
          if (rawLinksLineFrom !== line.from && isChipEligibleLink(view.state, node.node)) {
            activeChipLink = { from: node.from, to: node.to };
          }
          return;
        }

        // Chip layer replaces the whole eligible link; conceal must not double-decorate inside it.
        if (activeChipLink && node.from >= activeChipLink.from && node.to <= activeChipLink.to) {
          return;
        }

        const line = view.state.doc.lineAt(node.from);
        const isLinkConcealNode = LINK_CONCEAL_NODE_NAMES.has(node.name) && node.matchContext(['Link']);
        if (
          revealForSelection &&
          isLineSelected(view, line.from, line.to) &&
          (!isLinkConcealNode || rawLinksLineFrom === line.from)
        ) {
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
          let codeLine = view.state.doc.lineAt(from);

          while (codeLine.from < to) {
            if (!codeblockLineStarts.has(codeLine.from)) {
              codeblockLineStarts.add(codeLine.from);
              decorations.push(Decoration.line({ class: 'cm-codeblock-line' }).range(codeLine.from));
            }
            if (codeLine.to >= to || codeLine.number >= view.state.doc.lines) break;
            codeLine = view.state.doc.line(codeLine.number + 1);
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

const concealMouseDownPlugin = ViewPlugin.fromClass(class {
  private readonly window: Window;
  private readonly onMouseDown = (event: MouseEvent) => {
    if (event.button !== 0 || event.defaultPrevented) return;
    if (this.view.state.field(concealMouseDownField, false)) return;
    this.view.dispatch({ effects: setConcealMouseDownEffect.of(true) });
  };
  private readonly onMouseUp = () => {
    if (!this.view.state.field(concealMouseDownField, false)) return;
    this.view.dispatch({ effects: setConcealMouseDownEffect.of(false) });
  };

  constructor(private readonly view: EditorView) {
    this.window = view.dom.ownerDocument.defaultView ?? window;
    view.contentDOM.addEventListener('mousedown', this.onMouseDown);
    this.window.addEventListener('mouseup', this.onMouseUp);
  }

  destroy(): void {
    this.view.contentDOM.removeEventListener('mousedown', this.onMouseDown);
    this.window.removeEventListener('mouseup', this.onMouseUp);
  }
});

const markdownConcealPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildMarkdownConcealDecorations(view, {
      ensureInitialParse: true,
      revealForSelection: !view.state.field(concealMouseDownField, false),
    });
  }

  update(update: ViewUpdate): void {
    const rawLinksChanged = update.startState.field(revealRawLinksField, false) !==
      update.state.field(revealRawLinksField, false);
    const wasMouseDown = update.startState.field(concealMouseDownField, false) === true;
    const isMouseDown = update.state.field(concealMouseDownField, false) === true;

    if (
      update.docChanged ||
      update.viewportChanged ||
      update.selectionSet ||
      rawLinksChanged ||
      wasMouseDown !== isMouseDown
    ) {
      this.decorations = buildMarkdownConcealDecorations(update.view, {
        revealForSelection: !isMouseDown,
      });
    }
  }
}, {
  decorations: (value) => value.decorations,
});

export const markdownConcealExtension: Extension = [
  revealRawLinksField,
  concealMouseDownField,
  concealMouseDownPlugin,
  markdownConcealPlugin,
];
