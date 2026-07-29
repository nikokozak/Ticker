import { describe, expect, it } from 'vitest';
import type { Node as ProseNode } from 'prosemirror-model';
import { parseMarkdown, serializeMarkdown } from './markdown';
import { tickerSchema as S } from './schema';
import { normalizeForMarkdown } from './normalize';

/**
 * THE gate for a persistence codec: every document the EDITOR can create must
 * survive a save/reload unchanged.
 *
 *     doc.eq(parseMarkdown(serializeMarkdown(doc)))
 *
 * Not `canon(x) === canon(canon(x))`. That only proves the markdown settles, and a
 * document can settle after meaning has already been destroyed — a soft break plus
 * `---` settled beautifully into a setext heading that had eaten a line.
 *
 * Every case here is a shape a user can reach with the keyboard, so a failure is a
 * real bug rather than a curiosity.
 */

const t = (text: string) => S.text(text);
const p = (...content: ProseNode[]) => S.node('paragraph', null, content);
const doc = (...content: ProseNode[]) => S.node('doc', null, content);
const soft = () => S.node('soft_break');
const hard = () => S.node('hard_break');

function roundTrip(input: ProseNode): { out: string; back: ProseNode } {
  const out = serializeMarkdown(input);
  return { out, back: parseMarkdown(out) };
}

function expectClosed(raw: ProseNode): void {
  // The editor keeps documents normalised, so that is what must round-trip. Shapes
  // markdown cannot express (a break at a paragraph edge, two in a row, emphasis
  // wrapping flanking spaces) are removed here exactly as the editor removes them.
  const input = normalizeForMarkdown(raw);
  const { out, back } = roundTrip(input);
  // eq() compares structure, attrs and marks — not just the text.
  expect(back.eq(input), `reload changed the document.\n  markdown: ${JSON.stringify(out)}\n  before:   ${input.toString()}\n  after:    ${back.toString()}`).toBe(true);
  expect(serializeMarkdown(back)).toBe(out);
}

describe('break boundaries and adjacency', () => {
  const cases: Array<[string, ProseNode]> = [
    ['soft break between words', doc(p(t('foo'), soft(), t('bar')))],
    ['two adjacent soft breaks', doc(p(t('foo'), soft(), soft(), t('bar')))],
    ['three adjacent soft breaks', doc(p(t('foo'), soft(), soft(), soft(), t('bar')))],
    ['leading soft break', doc(p(soft(), t('foo')))],
    ['trailing soft break', doc(p(t('foo'), soft()))],
    ['soft break alone', doc(p(soft()))],
    ['hard break between words', doc(p(t('foo'), hard(), t('bar')))],
    ['two adjacent hard breaks', doc(p(t('foo'), hard(), hard(), t('bar')))],
    ['trailing hard break', doc(p(t('foo'), hard()))],
    ['hard then soft break', doc(p(t('foo'), hard(), soft(), t('bar')))],
    ['soft then hard break', doc(p(t('foo'), soft(), hard(), t('bar')))],
  ];
  for (const [name, node] of cases) it(name, () => expectClosed(node));
});

describe('whitespace at the edges of a line', () => {
  // Markdown strips it from every line, so without escaping these vanish on reload
  // — and a doubled trailing space silently turns into a hard break.
  const cases: Array<[string, ProseNode]> = [
    ['leading space in a paragraph', doc(p(t(' foo')))],
    ['leading spaces in a paragraph', doc(p(t('   foo')))],
    ['leading tab in a paragraph', doc(p(t('\tfoo')))],
    ['trailing space in a paragraph', doc(p(t('foo ')))],
    ['two trailing spaces in a paragraph', doc(p(t('foo  ')))],
    ['space at both ends', doc(p(t(' foo ')))],
    ['a paragraph of only spaces', doc(p(t('   ')))],
    ['space before a soft break', doc(p(t('foo '), soft(), t('bar')))],
    ['space after a soft break', doc(p(t('foo'), soft(), t(' bar')))],
    ['spaces around a soft break', doc(p(t('foo  '), soft(), t('  bar')))],
    ['space before a hard break', doc(p(t('foo '), hard(), t('bar')))],
    ['indented continuation line', doc(p(t('foo'), soft(), t('    indented')))],
    ['leading space in a heading', doc(S.node('heading', { level: 2 }, [t(' Title')]))],
    ['trailing space in a list item', doc(S.node('bullet_list', { tight: true }, [S.node('list_item', null, [p(t('item '))])]))],
    ['leading space inside a blockquote', doc(S.node('blockquote', null, [p(t(' quoted'))]))],
  ];
  for (const [name, node] of cases) it(name, () => expectClosed(node));
});

describe('block syntax at a line start created by a break', () => {
  const dangerous = ['# h', '## h', '> q', '- x', '* x', '+ x', '1. x', '0. x', '---', '***', '```', '~~~', '    indented', ': def', '| a |', '~~s~~', '[ ] task', '<u>', '{width=300}'];
  for (const text of dangerous) {
    it(`after a soft break: ${JSON.stringify(text)}`, () => expectClosed(doc(p(t('foo'), soft(), t(text)))));
    it(`after a hard break: ${JSON.stringify(text)}`, () => expectClosed(doc(p(t('foo'), hard(), t(text)))));
  }
});

describe('marked whitespace', () => {
  const bold = S.marks.strong.create();
  const under = S.marks.underline.create();
  it('bold around leading and trailing spaces', () => expectClosed(doc(p(t('a'), S.text(' b ', [bold]), t('c')))));
  it('underline around leading and trailing spaces', () => expectClosed(doc(p(t('a'), S.text(' b ', [under]), t('c')))));
  it('underline of a single space', () => expectClosed(doc(p(t('a'), S.text(' ', [under]), t('c')))));

  it('keeps whitespace INSIDE a mark run that spans several nodes', () => {
    // `**X1 — [link](url)**` is two strong nodes; the space before the link is
    // interior to the emphasis and markdown has no problem with it. A real stream
    // caught this being deleted.
    const link = S.marks.link.create({ href: 'https://x.test', title: null });
    const input = doc(p(S.text('X1 — ', [bold]), S.text('link', [bold, link])));
    expect(normalizeForMarkdown(input).eq(input)).toBe(true);
    expectClosed(input);
  });

  it('still expels whitespace at the outer edges of that run', () => {
    const link = S.marks.link.create({ href: 'https://x.test', title: null });
    const input = doc(p(S.text(' X1 — ', [bold]), S.text('link ', [bold, link])));
    expectClosed(input);
    expect(normalizeForMarkdown(input).textContent).toBe(' X1 — link ');
  });
});

describe('code blocks', () => {
  it('preserves a plain info string', () => expectClosed(doc(S.node('code_block', { params: 'ts' }, [t('const x = 1;')]))));
  it('preserves an info string containing a backtick', () => expectClosed(doc(S.node('code_block', { params: 'foo`bar' }, [t('code')]))));
  it('preserves content containing a fence', () => expectClosed(doc(S.node('code_block', { params: '' }, [t('```\ninner\n```')]))));
  it('preserves an empty code block', () => expectClosed(doc(S.node('code_block', { params: '' }, []))));
});

describe('lists', () => {
  const item = (text: string) => S.node('list_item', null, [p(t(text))]);
  it('ordered list starting at 3', () => expectClosed(doc(S.node('ordered_list', { order: 3, tight: true }, [item('a'), item('b')]))));
  it('ordered list starting at 0', () => expectClosed(doc(S.node('ordered_list', { order: 0, tight: true }, [item('a')]))));
  it('bullet list', () => expectClosed(doc(S.node('bullet_list', { tight: true }, [item('a'), item('b')]))));
  const quoteItem = () => S.node('list_item', null, [S.node('blockquote', null, [p(t('q'))])]);
  const codeItem = () => S.node('list_item', null, [S.node('code_block', { params: '' }, [t('x')])]);
  it('tight list item beginning with a blockquote', () => expectClosed(
    doc(S.node('bullet_list', { tight: true }, [quoteItem(), item('p')])),
  ));
  it('loose list item beginning with a blockquote', () => expectClosed(
    doc(S.node('bullet_list', { tight: false }, [quoteItem(), item('p')])),
  ));
  it('loose list item beginning with a code block', () => expectClosed(
    doc(S.node('ordered_list', { order: 1, tight: false }, [codeItem(), item('p')])),
  ));
  it('loose list whose first item is a paragraph keeps its looseness', () => {
    // The tightness rule must not flatten lists that CAN express it.
    const loose = doc(S.node('bullet_list', { tight: false }, [item('a'), item('b')]));
    expectClosed(loose);
    expect(normalizeForMarkdown(loose).firstChild?.attrs.tight).toBe(false);
  });
});

describe('images and links', () => {
  const img = (attrs: Record<string, unknown>) => S.node('image', attrs);
  it('asset image with width', () => expectClosed(doc(p(img({ src: 'ticker-asset://s/a.png', alt: 'x', title: null, width: 300 })))));
  it('asset image without width', () => expectClosed(doc(p(img({ src: 'ticker-asset://s/a.png', alt: 'x', title: null, width: null })))));
  it('image followed by literal width text', () => expectClosed(
    doc(p(img({ src: 'ticker-asset://s/a.png', alt: 'x', title: null, width: null }), t('{width=300}'))),
  ));
  it('citation link', () => expectClosed(
    doc(p(S.text('Book p.3', [S.marks.link.create({ href: 'ticker-pdf://s?page=3&q=a%20quote', title: null })]))),
  ));
  it('link whose text spans a soft break', () => {
    const link = S.marks.link.create({ href: 'https://x.test', title: null });
    expectClosed(doc(p(S.text('one', [link]), S.node('soft_break', null, undefined, [link]), S.text('two', [link]))));
  });
});

describe('link destinations survive a reload', () => {
  // A paste, a drop or an AI response can put any string in an href. Markdown
  // rewrites some of them and refuses others outright, so the editor holds hrefs
  // in the form markdown will give back.
  const linked = (href: string) => doc(p(S.text('text', [S.marks.link.create({ href, title: null })])));
  const hrefs = [
    'https://x.test/a b', // a space ENDS a destination — without canonicalising, the link vanishes
    'https://x.test/a<b>c',
    'https://x.test/a(b)',
    'https://x.test/a"b',
    'https://x.test/?q=a%20quote&r=1',
    'https://exämple.test/ä',
    'ticker-pdf://s?page=3&q=a%20quote',
    'ticker-asset://s/a.png',
    '#anchor',
    '',
  ];
  for (const href of hrefs) it(JSON.stringify(href), () => expectClosed(linked(href)));

  it('drops a link markdown would refuse rather than storing a dead one', () => {
    const doomed = linked('javascript:alert(1)');
    const normalized = normalizeForMarkdown(doomed);
    expect(normalized.textContent).toBe('text'); // the words are kept
    expect(normalized.rangeHasMark(0, normalized.content.size, S.marks.link)).toBe(false);
    expectClosed(doomed);
  });
});

describe('underline near link boundaries', () => {
  it('underline inside a link label', () => {
    const link = S.marks.link.create({ href: 'https://e.test', title: null });
    expectClosed(doc(p(S.text('x ', [link]), S.text('y', [link, S.marks.underline.create()]))));
  });
  it('underline spanning into text after a link', () => {
    const link = S.marks.link.create({ href: 'https://e.test', title: null });
    const under = S.marks.underline.create();
    expectClosed(doc(p(S.text('x', [link, under]), S.text(' z', [under]))));
  });
});
