import { EditorState, StateEffect, StateField, type Extension, type Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, WidgetType, type ViewUpdate } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';

// CONCEALMENT IS STATIC. Decorations depend only on the document, the viewport,
// and the explicit ⌥-click raw-line reveal — never on the selection or the
// mouse. Selection-driven reveal (per-line, then per-construct, then
// mousedown-frozen) produced an unstable feedback system: any click could
// reflow the page. A document must never shift because of where the cursor is.
// Raw markdown is summonable per line via ⌥-click, nothing else.
const MARK_NODE_NAMES = new Set(['EmphasisMark', 'StrongEmphasisMark', 'CodeMark', 'CodeInfo']);
const LINK_CONCEAL_NODE_NAMES = new Set(['LinkMark', 'URL', 'LinkTitle']);
const INITIAL_MARKDOWN_PARSE_TIMEOUT_MS = 20;

/** ⌥-click reveal: holds the start of the one line currently shown raw, or null. */
export const revealRawLinksEffect = StateEffect.define<number | null>();

/**
 * Footer "show formatting" toggle. True = the whole document renders raw:
 * every conceal decoration AND every link chip is disabled. One boolean, no
 * per-line choreography — the discoverable path to the markdown source.
 */
export const setShowRawFormattingEffect = StateEffect.define<boolean>();

const showRawFormattingField = StateField.define<boolean>({
  create: () => false,
  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setShowRawFormattingEffect)) value = effect.value;
    }
    return value;
  },
});

export function rawFormattingIsShown(state: EditorState): boolean {
  return state.field(showRawFormattingField, false) ?? false;
}

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

    // The raw line stays raw while the caret is on it; leaving the line re-conceals.
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

/** Current ⌥-click reveal line, for extensions that need to diff reveal state across updates. */
export function rawLinkRevealLine(state: EditorState): number | null {
  return state.field(revealRawLinksField, false) ?? null;
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

class BulletWidget extends WidgetType {
  override eq(): boolean {
    return true;
  }

  override toDOM(): HTMLElement {
    const bullet = document.createElement('span');
    bullet.className = 'cm-md-bullet';
    bullet.textContent = '•';
    return bullet;
  }
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

export function buildMarkdownConcealDecorations(view: EditorView, ensureInitialParse = false): DecorationSet {
  if (rawFormattingIsShown(view.state)) return Decoration.none;

  const decorations: Array<Range<Decoration>> = [];
  const blockquoteLineStarts = new Set<number>();
  const codeblockLineStarts = new Set<number>();
  const tree = markdownTreeForDecorations(view, ensureInitialParse);
  const rawLineFrom = view.state.field(revealRawLinksField, false);
  let skipLink: { from: number; to: number } | null = null;
  let pendingUnderlineOpen: { from: number; to: number } | null = null;

  for (const visibleRange of view.visibleRanges) {
    pendingUnderlineOpen = null;
    tree.iterate({
      from: visibleRange.from,
      to: visibleRange.to,
      enter: (node) => {
        // The ⌥-clicked raw line renders fully raw: no conceal decorations at all.
        if (rawLineFrom !== null && view.state.doc.lineAt(node.from).from === rawLineFrom && node.name !== 'FencedCode') {
          return;
        }

        if (node.name === 'Link') {
          // Chip links are replaced wholesale by the chip layer; incomplete links
          // render fully raw. Either way conceal leaves their innards alone.
          if (isChipEligibleLink(view.state, node.node) || !isCompleteLink(view.state, node.node)) {
            skipLink = { from: node.from, to: node.to };
          }
          return;
        }

        if (skipLink && node.from >= skipLink.from && node.to <= skipLink.to) {
          return;
        }

        if (node.name === 'HeaderMark') {
          const range = rangeWithFollowingSpace(view, node.from, node.to);
          const decoration = concealRange(range.from, range.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (node.name === 'ListMark') {
          // Bullet marks render as a real bullet; ordered-list numbers stay raw.
          const mark = view.state.doc.sliceString(node.from, node.to);
          if (/^[-*+]$/.test(mark)) {
            const range = rangeWithFollowingSpace(view, node.from, node.to);
            decorations.push(Decoration.replace({ widget: new BulletWidget() }).range(range.from, range.to));
          }
          return;
        }

        if (node.name === 'QuoteMark') {
          const line = view.state.doc.lineAt(node.from);
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

        // Underline rides inline HTML (<u>…</u>) — markdown has no syntax for
        // it. Only PAIRED tags conceal; an unmatched tag stays visibly raw so
        // it can be seen and deleted.
        if (node.name === 'HTMLTag') {
          const tag = view.state.doc.sliceString(node.from, node.to);
          if (/^<u\s*>$/i.test(tag)) {
            pendingUnderlineOpen = { from: node.from, to: node.to };
          } else if (/^<\/u\s*>$/i.test(tag) && pendingUnderlineOpen && pendingUnderlineOpen.to < node.from) {
            const open = pendingUnderlineOpen;
            pendingUnderlineOpen = null;
            const openConceal = concealRange(open.from, open.to);
            const closeConceal = concealRange(node.from, node.to);
            if (openConceal) decorations.push(openConceal);
            decorations.push(Decoration.mark({ class: 'cm-md-underline' }).range(open.to, node.from));
            if (closeConceal) decorations.push(closeConceal);
          }
          return;
        }

        if (MARK_NODE_NAMES.has(node.name)) {
          const decoration = concealRange(node.from, node.to);
          if (decoration) decorations.push(decoration);
          return;
        }

        if (node.name === 'Escape' && node.matchContext(['Link'])) {
          const decoration = concealRange(node.from, Math.min(node.from + 1, node.to));
          if (decoration) decorations.push(decoration);
          return;
        }

        // Citation-style links (ticker-pdf): syntax always concealed; ⌥-click is
        // the only way to see it raw.
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

// A throwing decoration build would make CodeMirror remove the plugin entirely —
// every conceal decoration vanishes at once and the document renders raw until
// remount. Never let that happen; keep the previous (mapped) set and log.
function safeBuild(view: EditorView, ensureInitialParse: boolean, fallback: DecorationSet): DecorationSet {
  try {
    return buildMarkdownConcealDecorations(view, ensureInitialParse);
  } catch (error) {
    console.error('[MarkdownConceal] decoration build failed', error);
    return fallback;
  }
}

const markdownConcealPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = safeBuild(view, true, Decoration.none);
  }

  update(update: ViewUpdate): void {
    const rawLineChanged = update.startState.field(revealRawLinksField, false) !==
      update.state.field(revealRawLinksField, false);
    const rawFormattingChanged = rawFormattingIsShown(update.startState) !== rawFormattingIsShown(update.state);

    if (update.docChanged || update.viewportChanged || rawLineChanged || rawFormattingChanged) {
      this.decorations = safeBuild(update.view, false, this.decorations.map(update.changes));
    }
  }
}, {
  decorations: (value) => value.decorations,
});

export const markdownConcealExtension: Extension = [
  revealRawLinksField,
  showRawFormattingField,
  markdownConcealPlugin,
];
