import { EditorState, StateEffect, StateField, type Extension, type Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode, SyntaxNodeRef } from '@lezer/common';

// Reveal model ported from Obsidian's live-preview semantics (reference:
// obsidian-latex-suite conceal.ts). Reveal is PER CONSTRUCT: a concealed mark
// expands only while a selection range touches its parent construct (the
// emphasis span, the heading, the inline-code span). Never whole lines — line
// reveal is what turned every caret move into layout reflow.
const MARK_NODE_NAMES = new Set(['EmphasisMark', 'StrongEmphasisMark', 'CodeMark', 'CodeInfo']);
const LINK_CONCEAL_NODE_NAMES = new Set(['LinkMark', 'URL', 'LinkTitle']);
const INITIAL_MARKDOWN_PARSE_TIMEOUT_MS = 20;

export const revealRawLinksEffect = StateEffect.define<number | null>();
const setConcealMouseDownEffect = StateEffect.define<boolean>();

function linkLabelRange(linkNode: SyntaxNode): { from: number; to: number } | null {
  const marks = linkNode.getChildren('LinkMark');
  if (marks.length < 2) return null;
  return { from: marks[0].to, to: marks[1].from };
}

/** Complete = non-empty label AND non-empty URL. Incomplete links render fully raw. */
export function isCompleteLink(state: EditorState, linkNode: SyntaxNode): boolean {
  const urlNode = linkNode.getChild('URL');
  if (!urlNode || urlNode.to <= urlNode.from) return false;
  const label = linkLabelRange(linkNode);
  if (!label || label.to <= label.from) return false;
  return state.doc.sliceString(label.from, label.to).trim().length > 0;
}

/** True for complete http(s) links — the chip layer replaces these wholesale. */
export function isChipEligibleLink(state: EditorState, linkNode: SyntaxNode): boolean {
  if (!isCompleteLink(state, linkNode)) return false;
  const urlNode = linkNode.getChild('URL');
  if (!urlNode) return false;
  const url = state.doc.sliceString(urlNode.from, urlNode.to);
  return /^https?:\/\//i.test(url);
}

/** Inclusive overlap, latex-suite style: touching an edge counts as overlap. */
export function selectionOverlapsRange(state: EditorState, from: number, to: number): boolean {
  return state.selection.ranges.some((range) => {
    const overlapFrom = Math.max(range.from, from);
    const overlapTo = Math.min(range.to, to);
    return overlapFrom <= overlapTo;
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

/** The construct whose selection-overlap reveals this concealed mark. */
function revealConstructRange(view: EditorView, node: SyntaxNodeRef): { from: number; to: number } {
  if (node.name === 'QuoteMark') {
    const line = view.state.doc.lineAt(node.from);
    return { from: line.from, to: line.to };
  }
  const parent = node.node.parent;
  return parent ? { from: parent.from, to: parent.to } : { from: node.from, to: node.to };
}

export interface MarkdownConcealBuildOptions {
  ensureInitialParse?: boolean;
  /**
   * When false (mouse held down), reveal is disabled entirely: everything stays
   * concealed so layout cannot shift under an in-progress drag. The set is still
   * rebuilt on every relevant update — freezing the DecorationSet itself desyncs
   * viewport coverage.
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
  let skipLink: { from: number; to: number } | null = null;

  for (const visibleRange of view.visibleRanges) {
    tree.iterate({
      from: visibleRange.from,
      to: visibleRange.to,
      enter: (node) => {
        if (node.name === 'Link') {
          const line = view.state.doc.lineAt(node.from);
          const rawRevealed = rawLinksLineFrom === line.from;
          // Chip links are replaced wholesale by the chip layer; incomplete
          // links render fully raw so they stay visible and editable. Either
          // way conceal leaves their innards alone.
          if (rawRevealed || isChipEligibleLink(view.state, node.node) || !isCompleteLink(view.state, node.node)) {
            skipLink = { from: node.from, to: node.to };
          }
          return;
        }

        if (skipLink && node.from >= skipLink.from && node.to <= skipLink.to) {
          return;
        }

        const isLinkConcealNode = LINK_CONCEAL_NODE_NAMES.has(node.name) && node.matchContext(['Link']);

        if (node.name === 'HeaderMark') {
          if (revealForSelection && selectionOverlapsRange(view.state, ...rangeTuple(revealConstructRange(view, node)))) return;
          const range = rangeWithFollowingSpace(view, node.from, node.to);
          const decoration = concealRange(range.from, range.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (node.name === 'QuoteMark') {
          const line = view.state.doc.lineAt(node.from);
          const construct = revealConstructRange(view, node);
          const revealed = revealForSelection && selectionOverlapsRange(view.state, construct.from, construct.to);
          if (!revealed) {
            const range = rangeWithFollowingSpace(view, node.from, node.to);
            const decoration = concealRange(range.from, range.to);
            if (decoration) decorations.push(decoration);
          }

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
          const construct = revealConstructRange(view, node);
          if (revealForSelection && selectionOverlapsRange(view.state, construct.from, construct.to)) return;
          const decoration = concealRange(node.from, node.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        // Citation-style links (ticker-pdf): syntax stays concealed regardless of
        // the caret; ⌥-click (revealRawLinks) is the only way to see it raw.
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

function rangeTuple(range: { from: number; to: number }): [number, number] {
  return [range.from, range.to];
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
    this.decorations = safeBuild(view, {
      ensureInitialParse: true,
      revealForSelection: !view.state.field(concealMouseDownField, false),
    }, Decoration.none);
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
      this.decorations = safeBuild(
        update.view,
        { revealForSelection: !isMouseDown },
        this.decorations.map(update.changes)
      );
    }
  }
}, {
  decorations: (value) => value.decorations,
});

// A throwing decoration build would make CodeMirror remove the plugin entirely —
// every conceal decoration vanishes at once and the document renders raw until
// remount. Never let that happen; keep the previous (mapped) set and log.
function safeBuild(
  view: EditorView,
  options: MarkdownConcealBuildOptions,
  fallback: DecorationSet
): DecorationSet {
  try {
    return buildMarkdownConcealDecorations(view, options);
  } catch (error) {
    console.error('[MarkdownConceal] decoration build failed', error);
    return fallback;
  }
}

export const markdownConcealExtension: Extension = [
  revealRawLinksField,
  concealMouseDownField,
  concealMouseDownPlugin,
  markdownConcealPlugin,
];
