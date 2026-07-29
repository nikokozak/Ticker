import MarkdownIt from 'markdown-it';
import type Token from 'markdown-it/lib/token.mjs';
import { MarkdownParser, MarkdownSerializer, MarkdownSerializerState } from 'prosemirror-markdown';
import type { Node as ProseNode } from 'prosemirror-model';
import { ASSET_URL_PREFIX, isValidImageWidth, tickerSchema } from './schema';

/**
 * The markdown codec. Markdown is Ticker's storage, AI and export format; it is
 * never the live editing model, so this file is the only place that knows the
 * syntax exists.
 *
 * Configuration is deliberately narrow, and every choice is load-bearing:
 *   html: false      every HTML-looking thing is literal text. Underline is matched
 *                    by a dedicated inline rule, so `<div>` or a stray `<u>` is
 *                    content, never an error.
 *   breaks: false    keeps softbreak tokens distinct from hard breaks, so an
 *                    authored newline can be put back as a newline.
 *   linkify: false   a bare URL stays text. Auto-linking would silently rewrite
 *                    the user's document on load.
 *   typographer: off no smart quotes or dash substitution — those mutate content.
 *   table/strike     left DISABLED. Measured: a table then parses to
 *                    text + soft_break + text and round-trips byte-exact, so
 *                    unsupported syntax is preserved verbatim rather than being
 *                    rejected or mangled. Nothing is refused, nothing is lost.
 */
export const markdownIt: MarkdownIt = MarkdownIt('commonmark', {
  // false on purpose: with HTML off, `<div>`, `<span>` and a stray `<u>` are all
  // ordinary text automatically. Underline gets its own inline rule instead, so
  // there is exactly one code path and nothing can arrive as an html token.
  html: false,
  breaks: false,
  linkify: false,
  typographer: false,
});

export class InvalidMarkdownError extends Error {
  constructor(readonly kind: string, message: string) {
    super(message);
    this.name = 'InvalidMarkdownError';
  }
}

/**
 * Text that markdown-it will DECODE on the way back in: `&amp;`, `&#32;`, `&copy;`.
 * Written out untouched, a literal `&amp;` a user typed reloads as a bare `&`, and
 * a literal `&#32;` reloads as a space. Only real entity syntax matches, so
 * ordinary text — "AT&T", "a & b" — is left alone and the markdown stays clean.
 */
const ENTITY_START = /&(?=[a-zA-Z][a-zA-Z0-9]*;|#\d+;|#[xX][0-9a-fA-F]+;)/g;

/** Escape entity syntax in a serialized attribute, where backslashes do not work. */
function escapeEntities(value: string): string {
  return value.replace(ENTITY_START, '&amp;');
}

const OPEN_UNDERLINE = /^<u\s*>/i;
const CLOSE_UNDERLINE = /^<\/u\s*>/i;
const WIDTH_SUFFIX = /^\{width=(\d{2,4})\}/;

/**
 * Underline rides inline HTML because markdown has no syntax for it. This emits
 * candidate tokens; pairing happens afterwards so an UNMATCHED tag can fall back
 * to being literal text. Nothing the user types is ever refused — the same
 * principle that lets tables survive as text.
 */
function underlineRule(
  state: { src: string; pos: number; posMax: number; push: (t: string, g: string, n: number) => Token },
  silent: boolean,
): boolean {
  if (state.src.charCodeAt(state.pos) !== 0x3c /* < */) return false;
  const rest = state.src.slice(state.pos, state.posMax);

  // Pushed with nesting 0 deliberately. A close token with nesting -1 that never
  // finds an open drives markdown-it's own level counter negative and crashes its
  // delimiter balancer, so nesting is assigned later, once pairing is known.
  const open = OPEN_UNDERLINE.exec(rest);
  if (open) {
    if (silent) { state.pos += open[0].length; return true; }
    const token = state.push('ticker_u_open', '', 0);
    token.markup = open[0];
    state.pos += open[0].length;
    return true;
  }

  const close = CLOSE_UNDERLINE.exec(rest);
  if (close) {
    if (silent) { state.pos += close[0].length; return true; }
    const token = state.push('ticker_u_close', '', 0);
    token.markup = close[0];
    state.pos += close[0].length;
    return true;
  }

  return false;
}

markdownIt.inline.ruler.before('text', 'ticker_underline', underlineRule as never);

/**
 * `{width=300}` immediately after an image becomes an attribute on that image
 * instead of literal text. An inline rule, so it can see the token it follows and
 * so an ESCAPED `\{width=300\}` — already turned into text by markdown-it — is
 * left alone. An out-of-range width is content the user typed, not an error: the
 * suffix simply stays text.
 */
function imageWidthRule(state: { src: string; pos: number; posMax: number; tokens: Token[]; pending: string }): boolean {
  if (state.src.charCodeAt(state.pos) !== 0x7b /* { */) return false;
  const match = WIDTH_SUFFIX.exec(state.src.slice(state.pos, state.posMax));
  if (!match) return false;

  // Must directly follow an image, with nothing — not even pending text — between.
  const previous = state.tokens[state.tokens.length - 1];
  if (state.pending.length > 0 || !previous || previous.type !== 'image') return false;
  if (!(previous.attrGet('src') ?? '').startsWith(ASSET_URL_PREFIX)) return false;

  const width = Number.parseInt(match[1], 10);
  if (!isValidImageWidth(width)) return false;

  previous.meta = { ...(previous.meta ?? {}), tickerWidth: width };
  state.pos += match[0].length;
  return true;
}

markdownIt.inline.ruler.before('text', 'ticker_image_width', imageWidthRule as never);

/**
 * Keep only tags that actually pair inside one inline context; revert the rest to
 * text. An unclosed `<u>` is something the user typed, not a parse failure.
 */
function resolveUnderline(tokens: Token[]): void {
  for (const token of tokens) {
    if (token.type !== 'inline' || !token.children) continue;

    const children = token.children;
    const paired = new Set<number>();
    let openIndex = -1;

    for (let i = 0; i < children.length; i += 1) {
      const kind = children[i].type;
      // Nested opens cannot pair; the inner one wins, the outer reverts to text.
      if (kind === 'ticker_u_open') openIndex = i;
      else if (kind === 'ticker_u_close' && openIndex >= 0) {
        paired.add(openIndex);
        paired.add(i);
        openIndex = -1;
      }
    }

    for (let i = 0; i < children.length; i += 1) {
      const child = children[i];
      const isOpen = child.type === 'ticker_u_open';
      if (!isOpen && child.type !== 'ticker_u_close') continue;

      if (paired.has(i)) {
        child.type = isOpen ? 'underline_open' : 'underline_close';
        child.tag = 'u';
        child.nesting = isOpen ? 1 : -1;
        continue;
      }

      child.type = 'text';
      child.content = child.markup;
      child.tag = '';
      child.nesting = 0;
    }
  }
}

markdownIt.core.ruler.push('ticker_underline_pairs', (state) => {
  resolveUnderline(state.tokens);
});

export const tickerMarkdownParser = new MarkdownParser(tickerSchema, markdownIt, {
  blockquote: { block: 'blockquote' },
  paragraph: { block: 'paragraph' },
  list_item: { block: 'list_item' },
  bullet_list: { block: 'bullet_list', getAttrs: (_, tokens, i) => ({ tight: listIsTight(tokens, i) }) },
  ordered_list: {
    block: 'ordered_list',
    getAttrs: (token, tokens, i) => ({
      order: token.attrGet('start') === null ? 1 : Number(token.attrGet('start')),
      tight: listIsTight(tokens, i),
    }),
  },
  heading: { block: 'heading', getAttrs: (token) => ({ level: Number(token.tag.slice(1)) }) },
  code_block: { block: 'code_block', noCloseToken: true },
  fence: { block: 'code_block', getAttrs: (token) => ({ params: token.info || '' }), noCloseToken: true },
  hr: { node: 'horizontal_rule' },
  image: {
    node: 'image',
    getAttrs: (token) => ({
      src: token.attrGet('src'),
      title: token.attrGet('title') || null,
      // Every child, not just the first. The stock spec reads children[0].content,
      // so an alt that tokenises into more than one piece — anything containing an
      // escape, or emphasis — silently loses everything after the first piece.
      alt: token.children?.map((child) => child.content).join('') || null,
      width: (token.meta as { tickerWidth?: number } | undefined)?.tickerWidth ?? null,
    }),
  },
  hardbreak: { node: 'hard_break' },
  softbreak: { node: 'soft_break' },
  em: { mark: 'em' },
  strong: { mark: 'strong' },
  underline: { mark: 'underline' },
  link: {
    mark: 'link',
    getAttrs: (token) => ({ href: token.attrGet('href'), title: token.attrGet('title') || null }),
  },
  code_inline: { mark: 'code', noCloseToken: true },
});

/**
 * markdown-it never marks looseness on the list itself; it marks it by HIDING the
 * paragraphs inside a tight one. So the signal is a `hidden` flag — but only on a
 * paragraph that is a DIRECT child of a list item.
 *
 * That distinction is the whole difficulty. In `* > q\n* p` the first item holds a
 * blockquote, and the paragraph inside that blockquote is never hidden either way.
 * Reading the first paragraph in the token stream therefore finds the blockquote's
 * and concludes, wrongly, that the two forms are identical. They are not: the
 * SECOND item has a direct paragraph, and it carries the flag.
 *
 * Measured, scanning direct paragraphs across every item:
 *
 *   `* > q\n* p`           [true]        tight
 *   `* > q\n\n* p`         [false]       loose
 *   "* ```\nx\n```\n* p"   []            no signal at all
 *
 * Only that last shape — where NO item has a direct paragraph — is genuinely
 * unrepresentable, and it is read as tight. normalizeForMarkdown applies the same
 * narrow rule, so the two agree and a save/reload is stable.
 */
function listIsTight(tokens: readonly Token[], index: number): boolean {
  let depth = 0;
  let itemDepth = -1;

  for (let i = index + 1; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type === 'list_item_open') {
      itemDepth = depth;
      depth += 1;
      continue;
    }
    if (token.type === 'paragraph_open' && depth === itemDepth + 1) return token.hidden;
    if (token.nesting === 1) depth += 1;
    else if (token.nesting === -1) {
      depth -= 1;
      if (depth < 0) break; // the end of this list
    }
  }

  return true;
}

/**
 * How many lists of this exact kind sit immediately before this one.
 *
 * Two adjacent lists of the same kind are ONE list in markdown — there is no blank
 * line that separates them, because a blank line inside a list only makes it loose.
 * So `* one` followed by a separate `* two` is written, reloaded, and comes back as
 * a single list with two items.
 *
 * That is not a cosmetic difference. Appending is how everything outside the editor
 * writes (the quick panel, the AI), so a stream whose last block is a list and whose
 * next append starts with one hits it immediately — and the merge SHIFTS every
 * position after it, so provenance spans stop covering the text they recorded.
 *
 * CommonMark's own answer is that changing the bullet character or the ordered
 * delimiter starts a new list. Alternating them keeps both lists, keeps each of them
 * tight, and changes nothing else about the document.
 */
function adjacentRun(parent: ProseNode | null, index: number): number {
  if (!parent) return 0;
  const type = parent.child(index).type;
  let run = 0;
  for (let i = index - 1; i >= 0 && parent.child(i).type === type; i -= 1) run += 1;
  return run;
}

function imageMarkdown(node: ProseNode, state: MarkdownSerializerState): string {
  // state.esc already applies escapeExtraCharacters, which covers entity syntax;
  // src and title are written raw and so need escapeEntities themselves.
  const alt = state.esc(node.attrs.alt || '');
  const src = escapeEntities(String(node.attrs.src).replace(/[()]/g, '\\$&'));
  const title = node.attrs.title ? ` "${escapeEntities(String(node.attrs.title).replace(/"/g, '\\"'))}"` : '';
  const width = node.attrs.width;

  if (width !== null) {
    if (!isValidImageWidth(width) || !String(node.attrs.src).startsWith(ASSET_URL_PREFIX)) {
      throw new InvalidMarkdownError('image_width', 'Only ticker-asset images may carry a valid width.');
    }
    return `![${alt}](${src}${title}){width=${width}}`;
  }
  return `![${alt}](${src}${title})`;
}

export const tickerMarkdownSerializer = new MarkdownSerializer({
  blockquote: (state, node) => state.wrapBlock('> ', null, node, () => state.renderContent(node)),
  code_block: (state, node) => {
    const params = node.attrs.params || '';
    const useTilde = params.includes('`');
    const marker = useTilde ? '~' : '`';
    const runs = node.textContent.match(useTilde ? /~{3,}/gm : /`{3,}/gm);
    const longest = runs ? Math.max(...runs.map((run) => run.length)) : 2;
    const fence = marker.repeat(Math.max(3, longest + 1));
    state.write(`${fence}${params}\n`);
    state.text(node.textContent, false);
    state.write('\n');
    state.write(fence);
    state.closeBlock(node);
  },
  heading: (state, node) => {
    state.write(`${'#'.repeat(node.attrs.level)} `);
    state.renderInline(node, false);
    state.closeBlock(node);
  },
  horizontal_rule: (state, node) => {
    state.write('---');
    state.closeBlock(node);
  },
  bullet_list: (state, node, parent, index) => {
    const marker = adjacentRun(parent, index) % 2 === 0 ? '*' : '-';
    state.renderList(node, '  ', () => `${marker} `);
  },
  ordered_list: (state, node, parent, index) => {
    const delimiter = adjacentRun(parent, index) % 2 === 0 ? '.' : ')';
    const start = node.attrs.order == null ? 1 : Number(node.attrs.order);
    const maxWidth = String(start + node.childCount - 1).length;
    const space = state.repeat(' ', maxWidth + 2);
    state.renderList(node, space, (i) => {
      const label = String(start + i);
      return `${state.repeat(' ', maxWidth - label.length)}${label}${delimiter} `;
    });
  },
  list_item: (state, node) => state.renderContent(node),
  paragraph: (state, node) => {
    state.renderInline(node);
    state.closeBlock(node);
  },
  image: (state, node) => state.write(imageMarkdown(node, state)),
  hard_break: (state, node, parent, index) => {
    for (let i = index + 1; i < parent.childCount; i += 1) {
      if (parent.child(i).type !== node.type) {
        state.write('\\\n');
        return;
      }
    }
  },
  // An authored newline goes back as a newline, not a space.
  soft_break: (state) => state.write('\n'),
  text: (state, node, parent, index) => {
    const text = node.text ?? '';
    const previous = index > 0 ? parent.child(index - 1).type.name : '';
    const afterBreak = previous === 'soft_break' || previous === 'hard_break';
    // A break starts a line just as the block boundary does.
    const startsLine = index === 0 || afterBreak;

    // Markdown strips whitespace from the start of every line, so indentation the
    // user typed is gone on reload. There is no escape for a space, but an entity
    // survives: markdown-it decodes entities even with html off, and they are
    // re-emitted here on the way back out.
    //
    // Only the START. Trailing whitespace is invisible, and preserving it would put
    // a `&#32;` on the end of nearly every paragraph — typing a word and pressing
    // Enter leaves one — which is real noise in a format the AI and exports read.
    // normalizeForMarkdown drops it instead, so the two agree.
    const leading = startsLine ? (/^[ \t]+/.exec(text)?.[0] ?? '') : '';
    if (leading) state.write(leading.replace(/ /g, '&#32;').replace(/\t/g, '&#9;'));

    // Once an entity is written the text is no longer at the start of a line, so
    // nothing after it can be read as block syntax.
    const core = text.slice(leading.length);
    if (core) writeLineStart(state, core, afterBreak && !leading);
  },
}, {
  em: { open: '*', close: '*', mixable: true, expelEnclosingWhitespace: true },
  strong: { open: '**', close: '**', mixable: true, expelEnclosingWhitespace: true },
  underline: { open: '<u>', close: '</u>', mixable: true },
  // Always the bracket form. The stock autolink shortcut (`<https://x>`) indexes
  // the sibling node and blew up on a link whose content spans a soft break; with
  // linkify off nothing needs it, and `[url](url)` round-trips identically.
  link: {
    open: () => '[',
    close: (_state, mark) => {
      const href = escapeEntities(String(mark.attrs.href).replace(/[()"]/g, '\\$&'));
      const title = mark.attrs.title
        ? ` "${escapeEntities(String(mark.attrs.title).replace(/"/g, '\\"'))}"`
        : '';
      return `](${href}${title})`;
    },
  },
  code: {
    open: (_state, _mark, parent, index) => backticksFor(parent.child(index), -1),
    close: (_state, _mark, parent, index) => backticksFor(parent.child(index - 1), 1),
    escape: false,
  },
}, {
  // Its own output must never be something its own parser would reinterpret:
  // literal `<u>`, a `{width=300}` a user typed, or the start of an HTML entity.
  escapeExtraCharacters: /[<>{}]|&(?=[a-zA-Z][a-zA-Z0-9]*;|#\d+;|#[xX][0-9a-fA-F]+;)/g,
});

/**
 * A soft break starts a new LINE, but prosemirror-markdown only applies its
 * start-of-line escaping at the start of a BLOCK. Without this, typing Shift+Enter
 * then '# x' reloads as a heading, '- x' as a list, and worst of all '---' turns
 * the whole paragraph into a setext heading and eats the line above it.
 */
function writeLineStart(state: MarkdownSerializerState, text: string, afterBreak: boolean): void {
  if (afterBreak) {
    const ordered = /^\d+\./.exec(text);
    if (ordered) {
      state.write(`${ordered[0].slice(0, -1)}\\.`);
      state.text(text.slice(ordered[0].length));
      return;
    }
    // Only characters nothing else escapes. '*' and '>' are already handled by the
    // inline escape and escapeExtraCharacters; prefixing them again would leave a
    // literal backslash in the user's text.
    if (/^[:#\-+]/.test(text)) {
      state.write('\\');
      state.text(text);
      return;
    }
  }
  state.text(text);
}

function backticksFor(node: ProseNode, side: number): string {
  const ticks = /`+/g;
  let len = 0;
  if (node.isText) {
    let match: RegExpExecArray | null;
    while ((match = ticks.exec(node.text ?? ''))) len = Math.max(len, match[0].length);
  }
  let result = len > 0 && side > 0 ? ' `' : '`';
  for (let i = 0; i < len; i += 1) result += '`';
  if (len > 0 && side < 0) result += ' ';
  return result;
}


/** markdown -> document. Throws InvalidMarkdownError on syntax Ticker cannot represent. */
export function parseMarkdown(markdown: string): ProseNode {
  return tickerMarkdownParser.parse(markdown);
}

/** document -> markdown. Output is always re-parseable by parseMarkdown. */
export function serializeMarkdown(doc: ProseNode): string {
  return tickerMarkdownSerializer.serialize(doc);
}
