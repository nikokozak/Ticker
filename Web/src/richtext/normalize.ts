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

/** Drop leading, trailing and repeated breaks in one inline sequence. */
function trimBreaks(children: ProseNode[]): ProseNode[] {
  const kept: ProseNode[] = [];
  for (const child of children) {
    if (isBreak(child)) {
      if (kept.length === 0) continue; // leading
      if (isBreak(kept[kept.length - 1])) continue; // repeated
    }
    kept.push(child);
  }
  while (kept.length && isBreak(kept[kept.length - 1])) kept.pop(); // trailing
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

/** Recursively rebuild the document with only representable inline sequences. */
export function normalizeForMarkdown(node: ProseNode): ProseNode {
  if (node.isTextblock) {
    const children: ProseNode[] = [];
    node.forEach((child) => children.push(canonicalizeLink(child)));
    return node.copy(Fragment.fromArray(trimBreaks(expelWhitespace(children))));
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
