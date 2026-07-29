import { Schema, type DOMOutputSpec, type MarkSpec, type NodeSpec } from 'prosemirror-model';
import { schema as base } from 'prosemirror-markdown';

/**
 * Ticker's document model: prosemirror-markdown's CommonMark schema plus exactly
 * three extensions, each forced by a measurement rather than a guess.
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
 * ponytail: extended rather than hand-copied. The copy had drifted from the
 * original in five places that only bite at the view layer — code_block dropped
 * its info string, ordered_list dropped `start`, list tightness was never emitted,
 * image dropped its width — because ProseMirror's internal clipboard round-trips
 * through the DOM, so a missing parseDOM attribute is silent data loss on copy.
 * Deriving keeps those rules correct by construction.
 *
 * ponytail: no raw_block node for unsupported syntax. Measured: with markdown-it's
 * table rule off, `| a | b |` parses to text + soft_break + text and round-trips
 * byte-exact, so nothing is lost or refused already. A raw_block would buy only a
 * monospace box around it. Add one if AI-emitted tables become common enough that
 * pipe-soup inline in prose is a real annoyance — capture a paragraph whose every
 * line matches a table row.
 */

/** Widths are clamped by the image UI; anything outside this is a malformed document. */
export const MIN_IMAGE_WIDTH = 120;
export const MAX_IMAGE_WIDTH = 920;
export const ASSET_URL_PREFIX = 'ticker-asset://';

export function isValidImageWidth(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= MIN_IMAGE_WIDTH && (value as number) <= MAX_IMAGE_WIDTH;
}

/**
 * Only ticker's own assets carry a width. A pasted `<img width=1200>` from a web
 * page must not smuggle one in, so the source is checked alongside the number.
 */
function readWidth(dom: HTMLElement): number | null {
  if (!(dom.getAttribute('src') ?? '').startsWith(ASSET_URL_PREFIX)) return null;
  const width = Number(dom.getAttribute('width'));
  return isValidImageWidth(width) ? width : null;
}

const image: NodeSpec = {
  ...base.spec.nodes.get('image'),
  attrs: { src: {}, alt: { default: null }, title: { default: null }, width: { default: null } },
  parseDOM: [{
    tag: 'img[src]',
    getAttrs: (dom: HTMLElement) => ({
      src: dom.getAttribute('src'),
      title: dom.getAttribute('title'),
      alt: dom.getAttribute('alt'),
      width: readWidth(dom),
    }),
  }],
  // Stock spreads node.attrs; `width` is a real <img> attribute, so it renders too.
  toDOM: (node): DOMOutputSpec => ['img', node.attrs],
};

/**
 * A newline the author typed inside a paragraph. Distinct from hard_break so the
 * serializer can put back exactly what was there: one literal newline.
 *
 * The priority is load-bearing. Both break nodes serialise to `<br>`, and the
 * stock `hard_break` rule matches ANY `br`, so at equal priority the schema order
 * decides — and hard_break is first. Copying a soft break inside the editor would
 * paste a hard break.
 */
const softBreak: NodeSpec = {
  inline: true,
  group: 'inline',
  selectable: false,
  parseDOM: [{ tag: 'br[data-soft-break]', priority: 60 }],
  toDOM: (): DOMOutputSpec => ['br', { 'data-soft-break': 'true' }],
  // Without this a break is nothing at all in plain text, so copying a paragraph
  // and pasting it somewhere else runs the two lines together.
  leafText: () => '\n',
};

/**
 * The stock hard break, tagged.
 *
 * A contenteditable browser puts a padding `<br>` at the end of a block, so
 * ProseMirror's clipboard IGNORES a trailing `<br>` — which silently ate a real
 * break whenever a copied selection ended on one. The attribute is what lets the
 * clipboard parser tell our break from the browser's filler; see BREAK_ATTRIBUTES.
 */
const hardBreak: NodeSpec = {
  ...base.spec.nodes.get('hard_break'),
  toDOM: (): DOMOutputSpec => ['br', { 'data-hard-break': 'true' }],
  leafText: () => '\n',
};

/** Attributes marking a `<br>` this editor produced rather than the browser. */
export const BREAK_ATTRIBUTES = ['data-soft-break', 'data-hard-break'];

const underline: MarkSpec = {
  parseDOM: [{ tag: 'u' }, { style: 'text-decoration=underline' }],
  toDOM: (): DOMOutputSpec => ['u', 0],
};

export const tickerSchema = new Schema({
  nodes: base.spec.nodes.update('image', image).update('hard_break', hardBreak).addToEnd('soft_break', softBreak),
  // Before `em` so underline is the outermost mark, which fixes one canonical
  // nesting and keeps serialisation deterministic.
  marks: base.spec.marks.addBefore('em', 'underline', underline),
});
