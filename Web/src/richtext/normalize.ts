import { Fragment, type Node as ProseNode } from 'prosemirror-model';
import { tickerSchema } from './schema';

/**
 * Not every ProseMirror document can be written as markdown. These shapes are
 * reachable with the keyboard but have no markdown spelling:
 *
 *   - two line breaks in a row inside one paragraph — a blank line always ENDS a
 *     paragraph, so `foo\n\nbar` reloads as two paragraphs;
 *   - a break at the very start or end of a paragraph — markdown trims it;
 *   - emphasis wrapping flanking whitespace — `** b **` is not emphasis at all,
 *     so the spaces must sit outside the marker.
 *
 * The codec defines what is representable; this projects any document into that
 * set. The editor runs it on every transaction, so an unrepresentable document
 * can never be persisted and a save/reload can never surprise the user.
 *
 * ponytail: normalising is one pass over the doc rather than guards on every
 * command, because paste, drop and AI insertion can all create these too, and one
 * chokepoint beats five.
 */

const { em, strong } = tickerSchema.marks;
/** Marks markdown cannot wrap around flanking whitespace. Underline (HTML) can. */
const WHITESPACE_INTOLERANT = [em, strong];

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

/** Move whitespace that emphasis cannot legally wrap to just outside the mark. */
function expelWhitespace(children: ProseNode[]): ProseNode[] {
  const out: ProseNode[] = [];

  for (const child of children) {
    if (!child.isText || !child.text) {
      out.push(child);
      continue;
    }

    const offending = WHITESPACE_INTOLERANT.filter((mark) => mark.isInSet(child.marks));
    const leading = /^\s+/.exec(child.text)?.[0] ?? '';
    const trailing = child.text.length > leading.length ? (/\s+$/.exec(child.text)?.[0] ?? '') : '';
    if (!offending.length || (!leading && !trailing)) {
      out.push(child);
      continue;
    }

    const core = child.text.slice(leading.length, child.text.length - trailing.length);
    const outerMarks = child.marks.filter((mark) => !offending.some((bad) => bad === mark.type));
    if (leading) out.push(tickerSchema.text(leading, outerMarks));
    if (core) out.push(tickerSchema.text(core, child.marks));
    if (trailing) out.push(tickerSchema.text(trailing, outerMarks));
  }

  return out;
}

/** Recursively rebuild the document with only representable inline sequences. */
export function normalizeForMarkdown(node: ProseNode): ProseNode {
  if (node.isTextblock) {
    const children: ProseNode[] = [];
    node.forEach((child) => children.push(child));
    return node.copy(Fragment.fromArray(trimBreaks(expelWhitespace(children))));
  }

  if (node.isLeaf) return node;

  const children: ProseNode[] = [];
  node.forEach((child) => children.push(normalizeForMarkdown(child)));
  return node.copy(Fragment.fromArray(children));
}

/** True when the document is already representable — nothing would change. */
export function isNormalized(doc: ProseNode): boolean {
  return normalizeForMarkdown(doc).eq(doc);
}
