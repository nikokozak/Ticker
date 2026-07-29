import { Fragment, type Node as ProseNode } from 'prosemirror-model';
import { markdownIt } from './markdown';
import { tickerSchema } from './schema';

/**
 * Not every ProseMirror document can be written as markdown. These shapes are
 * reachable with the keyboard but have no markdown spelling:
 *
 *   - two line breaks in a row inside one paragraph — a blank line always ENDS a
 *     paragraph, so `foo\n\nbar` reloads as two paragraphs;
 *   - a break at the very start or end of a paragraph — markdown trims it;
 *   - emphasis wrapping flanking whitespace — `** b **` is not emphasis at all,
 *     so the spaces must sit outside the marker;
 *   - whitespace at the end of a line — markdown strips it, and two trailing
 *     spaces are a hard break;
 *   - a link href markdown would rewrite — a space in a destination ends it, so
 *     `[x](https://h/a b)` is not a link at all and the link is silently lost;
 *   - looseness on a list whose first item starts with a blockquote or a code
 *     block — markdown-it emits identical tokens for the tight and loose forms,
 *     so the distinction cannot survive a reload.
 *
 * The codec defines what is representable; this projects any document into that
 * set. The editor runs it on every transaction, so an unrepresentable document
 * can never be persisted and a save/reload can never surprise the user.
 *
 * ponytail: normalising is one pass over the doc rather than guards on every
 * command, because paste, drop and AI insertion can all create these too, and one
 * chokepoint beats five.
 */

const { em, link, strong } = tickerSchema.marks;
/** Marks markdown cannot wrap around flanking whitespace. Underline (HTML) can. */
const WHITESPACE_INTOLERANT = [em, strong];
const LIST_TYPES = new Set(['bullet_list', 'ordered_list']);

/**
 * The href a link would have after a save and reload. markdown-it percent-encodes
 * destinations on the way in, so an href the editor invented (from a paste, a drop,
 * or an AI response) must be put through the same function or it comes back
 * different — or, when it contains a space, comes back as plain text with the link
 * gone entirely.
 *
 * Returns null for a destination markdown-it will not accept as a link at all,
 * which is also the `javascript:` guard: such an href never reaches the view.
 */
function canonicalHref(href: string): string | null {
  let normalized: string;
  try {
    normalized = markdownIt.normalizeLink(href);
  } catch {
    return null; // malformed percent-escapes; mdurl throws rather than returning
  }
  return markdownIt.validateLink(normalized) ? normalized : null;
}

/** Rewrite or drop a node's link mark so the href survives a round-trip. */
function canonicalizeLink(node: ProseNode): ProseNode {
  const mark = link.isInSet(node.marks);
  if (!mark) return node;

  const href = canonicalHref(String(mark.attrs.href ?? ''));
  const without = link.removeFromSet(node.marks);
  if (href === null) return node.mark(without);
  if (href === mark.attrs.href) return node;
  return node.mark(link.create({ ...mark.attrs, href }).addToSet(without));
}

function isBreak(node: ProseNode): boolean {
  return node.type.name === 'soft_break' || node.type.name === 'hard_break';
}

/**
 * Drop only the breaks markdown cannot write down. Measured, not assumed:
 *
 *   `foo\ \ bar`   two hard breaks    ROUND-TRIPS — so Shift+Enter twice works
 *   `\ foo`        leading hard break ROUND-TRIPS
 *   `foo \ bar`    soft then hard     ROUND-TRIPS
 *   `foo\ \n bar`  hard then soft     lost: the two together make a blank line,
 *                                     which ends the paragraph
 *   `foo\n\nbar`   two soft breaks    lost, same reason
 *   `\nfoo`        leading soft break lost: markdown trims it
 *   anything at the END of a block    lost: markdown trims it
 *
 * So a soft break cannot open a line or follow another break, and no break can
 * end a block. Everything else stays, which is what makes repeated Shift+Enter
 * behave the way a writer expects instead of silently collapsing.
 */
function trimBreaks(children: ProseNode[]): ProseNode[] {
  const kept: ProseNode[] = [];
  for (const child of children) {
    if (child.type === tickerSchema.nodes.soft_break) {
      if (kept.length === 0) continue; // opens the line
      if (isBreak(kept[kept.length - 1])) continue; // makes a blank line
    }
    kept.push(child);
  }
  while (kept.length && isBreak(kept[kept.length - 1])) kept.pop(); // ends the block
  return kept;
}

/**
 * Move whitespace that emphasis cannot legally wrap to just outside the mark.
 *
 * Only at the EDGES of a mark run. `**X1 — [link](url)**` is two inline nodes that
 * both carry `strong`, and the space before the link is interior to the emphasis,
 * where markdown is perfectly happy with it. Treating every text node as its own
 * run deletes spaces out of the middle of bold text — which is how a real stream
 * caught this.
 */
function expelWhitespace(children: ProseNode[]): ProseNode[] {
  const out: ProseNode[] = [];

  for (let i = 0; i < children.length; i += 1) {
    const child = children[i];
    if (!child.isText || !child.text) {
      out.push(child);
      continue;
    }

    // A mark only has an edge here if the neighbour on that side lacks it.
    const opensHere = WHITESPACE_INTOLERANT.filter(
      (mark) => mark.isInSet(child.marks) && !(i > 0 && mark.isInSet(children[i - 1].marks)),
    );
    const closesHere = WHITESPACE_INTOLERANT.filter(
      (mark) => mark.isInSet(child.marks) && !(i + 1 < children.length && mark.isInSet(children[i + 1].marks)),
    );

    const leading = opensHere.length ? (/^\s+/.exec(child.text)?.[0] ?? '') : '';
    const trailing = closesHere.length && child.text.length > leading.length
      ? (/\s+$/.exec(child.text)?.[0] ?? '')
      : '';
    if (!leading && !trailing) {
      out.push(child);
      continue;
    }

    // The expelled whitespace keeps every mark except the ones whose edge is here,
    // so a run continuing from a neighbour is left intact.
    const core = child.text.slice(leading.length, child.text.length - trailing.length);
    const without = (drop: typeof opensHere) => child.marks.filter((mark) => !drop.includes(mark.type));
    if (leading) out.push(tickerSchema.text(leading, without(opensHere)));
    if (core) out.push(tickerSchema.text(core, child.marks));
    if (trailing) out.push(tickerSchema.text(trailing, without(closesHere)));
  }

  return out;
}

/**
 * A list is read back as tight unless its first item starts with a paragraph, so
 * force that here rather than storing a looseness the reload will not honour.
 */
function normalizeTightness(node: ProseNode): ProseNode {
  if (!LIST_TYPES.has(node.type.name) || node.attrs.tight) return node;
  if (node.firstChild?.firstChild?.type === tickerSchema.nodes.paragraph) return node;
  return node.type.create({ ...node.attrs, tight: true }, node.content, node.marks);
}

/**
 * Drop whitespace at the end of a line. Markdown strips it, and two trailing
 * spaces are a hard break, so it cannot simply be written out. It could be escaped
 * the way leading indentation is, but a trailing space is invisible and typing a
 * word then pressing Enter leaves one, so escaping would put a `&#32;` on the end
 * of nearly every paragraph in a format the AI and exports read.
 */
function trimLineEnds(children: ProseNode[]): ProseNode[] {
  const out: ProseNode[] = [];

  for (let i = 0; i < children.length; i += 1) {
    const child = children[i];
    const endsLine = i + 1 === children.length || isBreak(children[i + 1]);
    if (!endsLine || !child.isText || !child.text) {
      out.push(child);
      continue;
    }

    const trimmed = child.text.replace(/[ \t]+$/, '');
    if (trimmed === child.text) out.push(child);
    else if (trimmed) out.push(tickerSchema.text(trimmed, child.marks));
    // else: the node was only whitespace, so it disappears entirely
  }

  return out;
}

/**
 * Drop whitespace at the very start of a block. Splitting "bold text" after the
 * word leaves a paragraph beginning with a space, which is an artifact of the edit
 * rather than something anyone typed on purpose — and writing it out means a
 * `&#32;` at the head of the paragraph, in a format the AI reads back.
 *
 * Indentation AFTER a line break is left alone: that one is deliberate, and it is
 * the only way to indent inside a paragraph.
 */
function trimBlockStart(children: ProseNode[]): ProseNode[] {
  const first = children[0];
  if (!first?.isText || !first.text) return children;

  const trimmed = first.text.replace(/^[ \t]+/, '');
  if (trimmed === first.text) return children;
  const rest = children.slice(1);
  return trimmed ? [tickerSchema.text(trimmed, first.marks), ...rest] : rest;
}

/** Recursively rebuild the document with only representable inline sequences. */
export function normalizeForMarkdown(node: ProseNode): ProseNode {
  if (node.isTextblock) {
    const children: ProseNode[] = [];
    node.forEach((child) => children.push(canonicalizeLink(child)));
    // Trim line ends BEFORE trimming breaks: dropping a whitespace-only node can
    // leave two breaks adjacent, and that pair may not be representable.
    return node.copy(Fragment.fromArray(trimBreaks(trimBlockStart(trimLineEnds(expelWhitespace(children))))));
  }

  if (node.isLeaf) return node;

  const children: ProseNode[] = [];
  node.forEach((child) => children.push(normalizeForMarkdown(child)));
  return normalizeTightness(node.copy(Fragment.fromArray(children)));
}

/** True when the document is already representable — nothing would change. */
export function isNormalized(doc: ProseNode): boolean {
  return normalizeForMarkdown(doc).eq(doc);
}
