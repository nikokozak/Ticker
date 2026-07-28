import { Schema, type MarkSpec, type NodeSpec } from 'prosemirror-model';

/**
 * Ticker's document model: stock ProseMirror CommonMark plus exactly three
 * extensions, each forced by a measurement rather than a guess.
 *
 *   soft_break   a single newline inside a paragraph is a markdown soft break and
 *                otherwise arrives as a SPACE, silently turning an authored line
 *                break into a space. Unacceptable in a writing app, and not
 *                repairable later — by serialisation time the parser has already
 *                forgotten whether the space was typed or was a newline.
 *   underline    `<u>` survives markdown round-trips as literal text, so without a
 *                mark the tags are visible characters and underline is not a
 *                concept the editor can apply or remove.
 *   image.width  `{width=N}` sits beside the image node as literal text, i.e.
 *                visible markup, which is the exact class of bug this rewrite
 *                exists to eliminate.
 *
 * Everything else is deliberately absent. Citations are ordinary links carrying a
 * `ticker-pdf://` href — no citation node, no link subtype. Provenance spans and
 * margin notes stay external metadata and never become marks or nodes.
 *
 * ponytail: no raw_block node for unsupported syntax. Measured: with markdown-it's
 * table rule off, `| a | b |` parses to text + soft_break + text and round-trips
 * byte-exact, so nothing is lost or refused already. A raw_block would buy only a
 * monospace box around it. Add one if AI-emitted tables become common enough that
 * pipe-soup inline in prose is a real annoyance — capture a paragraph whose every
 * line matches a table row.
 */

const nodes: Record<string, NodeSpec> = {
  doc: { content: 'block+' },

  paragraph: {
    content: 'inline*',
    group: 'block',
    parseDOM: [{ tag: 'p' }],
    toDOM: () => ['p', 0],
  },

  blockquote: {
    content: 'block+',
    group: 'block',
    defining: true,
    parseDOM: [{ tag: 'blockquote' }],
    toDOM: () => ['blockquote', 0],
  },

  horizontal_rule: {
    group: 'block',
    parseDOM: [{ tag: 'hr' }],
    toDOM: () => ['hr'],
  },

  heading: {
    attrs: { level: { default: 1 } },
    content: '(text | image)*',
    group: 'block',
    defining: true,
    parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({ tag: `h${level}`, attrs: { level } })),
    toDOM: (node) => [`h${node.attrs.level}`, 0],
  },

  code_block: {
    attrs: { params: { default: '' } },
    content: 'text*',
    marks: '',
    group: 'block',
    code: true,
    defining: true,
    parseDOM: [{ tag: 'pre', preserveWhitespace: 'full' }],
    toDOM: () => ['pre', ['code', 0]],
  },

  ordered_list: {
    attrs: { order: { default: 1 }, tight: { default: false } },
    content: 'list_item+',
    group: 'block',
    parseDOM: [{ tag: 'ol' }],
    toDOM: (node) => ['ol', { start: node.attrs.order === 1 ? null : node.attrs.order }, 0],
  },

  bullet_list: {
    attrs: { tight: { default: false } },
    content: 'list_item+',
    group: 'block',
    parseDOM: [{ tag: 'ul' }],
    toDOM: () => ['ul', 0],
  },

  list_item: {
    content: 'block+',
    defining: true,
    parseDOM: [{ tag: 'li' }],
    toDOM: () => ['li', 0],
  },

  text: { group: 'inline' },

  image: {
    inline: true,
    attrs: {
      src: {},
      alt: { default: null },
      title: { default: null },
      // Only ever set for ticker-asset:// images; see markdown.ts for validation.
      width: { default: null },
    },
    group: 'inline',
    draggable: true,
    parseDOM: [{
      tag: 'img[src]',
      getAttrs: (dom) => ({
        src: (dom as HTMLElement).getAttribute('src'),
        alt: (dom as HTMLElement).getAttribute('alt'),
        title: (dom as HTMLElement).getAttribute('title'),
      }),
    }],
    toDOM: (node) => ['img', {
      src: node.attrs.src,
      alt: node.attrs.alt,
      title: node.attrs.title,
      width: node.attrs.width,
    }],
  },

  /** An explicit markdown hard break (`\` or two trailing spaces). */
  hard_break: {
    inline: true,
    group: 'inline',
    selectable: false,
    parseDOM: [{ tag: 'br' }],
    toDOM: () => ['br'],
  },

  /**
   * A newline the author typed inside a paragraph. Distinct from hard_break so the
   * serializer can put back exactly what was there: one literal newline.
   */
  soft_break: {
    inline: true,
    group: 'inline',
    selectable: false,
    parseDOM: [{ tag: 'br[data-soft-break]' }],
    toDOM: () => ['br', { 'data-soft-break': 'true' }],
  },
};

// Order matters: it fixes canonical nesting, with underline outermost and code
// innermost, so serialisation is deterministic.
const marks: Record<string, MarkSpec> = {
  underline: {
    parseDOM: [{ tag: 'u' }],
    toDOM: () => ['u', 0],
  },

  em: {
    parseDOM: [{ tag: 'i' }, { tag: 'em' }, { style: 'font-style=italic' }],
    toDOM: () => ['em', 0],
  },

  strong: {
    parseDOM: [{ tag: 'b' }, { tag: 'strong' }],
    toDOM: () => ['strong', 0],
  },

  link: {
    attrs: { href: {}, title: { default: null } },
    inclusive: false,
    parseDOM: [{
      tag: 'a[href]',
      getAttrs: (dom) => ({
        href: (dom as HTMLElement).getAttribute('href'),
        title: (dom as HTMLElement).getAttribute('title'),
      }),
    }],
    toDOM: (mark) => ['a', mark.attrs, 0],
  },

  code: {
    code: true,
    parseDOM: [{ tag: 'code' }],
    toDOM: () => ['code', 0],
  },
};

export const tickerSchema = new Schema({ nodes, marks });

/** Widths are clamped by the image UI; anything outside this is a malformed document. */
export const MIN_IMAGE_WIDTH = 120;
export const MAX_IMAGE_WIDTH = 920;
export const ASSET_URL_PREFIX = 'ticker-asset://';

export function isValidImageWidth(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= MIN_IMAGE_WIDTH && (value as number) <= MAX_IMAGE_WIDTH;
}
