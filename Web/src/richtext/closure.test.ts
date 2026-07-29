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

/**
 * The gate, and the gate has to be honest about its own weakness.
 *
 * An earlier version normalised its input and then asserted closure on the result,
 * which means a case could pass by having the very thing under test DELETED — a
 * paragraph ending in a break "round-tripped" beautifully once the break was gone.
 *
 * So this asserts three things:
 *   1. normalisation settles — running it twice changes nothing more;
 *   2. the persisted form is closed — what is saved reloads identically;
 *   3. normalisation is a no-op, UNLESS the case says otherwise via expectNormalized.
 *
 * Point 3 is what makes it honest: a case that quietly loses content now fails,
 * because it never declared that it would lose any.
 */
function expectClosed(raw: ProseNode): void {
  const input = normalizeForMarkdown(raw);

  expect(normalizeForMarkdown(input).eq(input), `normalisation does not settle.\n  once:  ${input.toString()}\n  twice: ${normalizeForMarkdown(input).toString()}`).toBe(true);

  const { out, back } = roundTrip(input);
  // eq() compares structure, attrs and marks — not just the text.
  expect(back.eq(input), `reload changed the document.\n  markdown: ${JSON.stringify(out)}\n  before:   ${input.toString()}\n  after:    ${back.toString()}`).toBe(true);
  expect(serializeMarkdown(back)).toBe(out);

  if (!declaredLossy.has(raw)) {
    expect(input.eq(raw), `normalisation changed the document but the test never said it would — so this case may be passing only because the thing it tests was deleted.\n  before: ${raw.toString()}\n  after:  ${input.toString()}\nIf the change is intended, wrap the case in expectNormalized(raw, expectedMarkdown).`).toBe(true);
  }
}

/** Cases that intentionally lose something on the way to markdown. */
const declaredLossy = new WeakSet<ProseNode>();

/**
 * For a shape markdown genuinely cannot hold: declare exactly what it becomes.
 * Naming the result is the point — it is the difference between a documented
 * policy and silent data loss.
 */
function expectNormalized(raw: ProseNode, markdown: string): void {
  declaredLossy.add(raw);
  expect(serializeMarkdown(normalizeForMarkdown(raw))).toBe(markdown);
  expectClosed(raw);
}

describe('break boundaries and adjacency', () => {
  // A soft break cannot open a line or follow another break (either makes a blank
  // line, which ends the paragraph), and no break can end a block. Each lossy case
  // states what it becomes; the rest must survive untouched.
  const kept: Array<[string, ProseNode]> = [
    ['soft break between words', doc(p(t('foo'), soft(), t('bar')))],
    ['hard break between words', doc(p(t('foo'), hard(), t('bar')))],
    ['two adjacent hard breaks', doc(p(t('foo'), hard(), hard(), t('bar')))],
    ['soft then hard break', doc(p(t('foo'), soft(), hard(), t('bar')))],
  ];
  for (const [name, node] of kept) it(name, () => expectClosed(node));

  const lossy: Array<[string, ProseNode, string]> = [
    ['two adjacent soft breaks collapse to one', doc(p(t('foo'), soft(), soft(), t('bar'))), 'foo\nbar'],
    ['three adjacent soft breaks collapse to one', doc(p(t('foo'), soft(), soft(), soft(), t('bar'))), 'foo\nbar'],
    ['a leading soft break is dropped', doc(p(soft(), t('foo'))), 'foo'],
    ['a trailing soft break is dropped', doc(p(t('foo'), soft())), 'foo'],
    ['a paragraph of only a soft break empties', doc(p(soft())), ''],
    ['a trailing hard break is dropped', doc(p(t('foo'), hard())), 'foo'],
    ['a soft break after a hard break is dropped', doc(p(t('foo'), hard(), soft(), t('bar'))), 'foo\\\nbar'],
  ];
  for (const [name, node, markdown] of lossy) it(name, () => expectNormalized(node, markdown));

  // Pressing Shift+Enter twice must actually leave a blank line, not silently
  // collapse to one. Hard breaks repeat fine; only the shapes markdown genuinely
  // cannot write are removed.
  it('keeps two hard breaks', () => {
    const input = doc(p(t('foo'), hard(), hard(), t('bar')));
    expect(normalizeForMarkdown(input).eq(input)).toBe(true);
    expectClosed(input);
  });
  it('keeps three hard breaks', () => {
    const input = doc(p(t('foo'), hard(), hard(), hard(), t('bar')));
    expect(normalizeForMarkdown(input).eq(input)).toBe(true);
    expectClosed(input);
  });
  it('keeps a leading hard break', () => {
    const input = doc(p(hard(), t('foo')));
    expect(normalizeForMarkdown(input).eq(input)).toBe(true);
    expectClosed(input);
  });
  it('keeps a soft break followed by a hard break', () => {
    const input = doc(p(t('foo'), soft(), hard(), t('bar')));
    expect(normalizeForMarkdown(input).eq(input)).toBe(true);
    expectClosed(input);
  });
});

describe('whitespace at the edges of a line', () => {
  // Markdown strips it from both ends of every line, so each case is either escaped
  // or deliberately dropped. Indentation typed after a line break is kept, because
  // it is the only way to indent inside a paragraph. Whitespace at a block's start
  // or at any line's end is dropped: it is invisible or an artifact of an edit, and
  // escaping it would put a `&#32;` in nearly every paragraph of a format the AI
  // reads back.
  const kept: Array<[string, ProseNode]> = [
    ['space after a soft break', doc(p(t('foo'), soft(), t(' bar')))],
    ['indented continuation line', doc(p(t('foo'), soft(), t('    indented')))],
  ];
  for (const [name, node] of kept) it(name, () => expectClosed(node));

  const dropped: Array<[string, ProseNode, string]> = [
    ['a leading space in a paragraph', doc(p(t(' foo'))), 'foo'],
    ['leading spaces in a paragraph', doc(p(t('   foo'))), 'foo'],
    ['a leading tab in a paragraph', doc(p(t('\tfoo'))), 'foo'],
    ['a trailing space in a paragraph', doc(p(t('foo '))), 'foo'],
    ['two trailing spaces in a paragraph', doc(p(t('foo  '))), 'foo'],
    ['a space at both ends', doc(p(t(' foo '))), 'foo'],
    ['a paragraph of only spaces', doc(p(t('   '))), ''],
    ['a space before a soft break', doc(p(t('foo '), soft(), t('bar'))), 'foo\nbar'],
    ['spaces around a soft break', doc(p(t('foo  '), soft(), t('  bar'))), 'foo\n&#32;&#32;bar'],
    ['a space before a hard break', doc(p(t('foo '), hard(), t('bar'))), 'foo\\\nbar'],
    ['a leading space in a heading', doc(S.node('heading', { level: 2 }, [t(' Title')])), '## Title'],
    ['a trailing space in a list item', doc(S.node('bullet_list', { tight: true }, [S.node('list_item', null, [p(t('item '))])])), '* item'],
    ['a leading space inside a blockquote', doc(S.node('blockquote', null, [p(t(' quoted'))])), '> quoted'],
  ];
  for (const [name, node, markdown] of dropped) it(`drops ${name}`, () => expectNormalized(node, markdown));

  it('keeps indentation typed after a line break, which is deliberate', () => {
    const indented = doc(p(t('foo'), soft(), t('   bar')));
    expect(serializeMarkdown(normalizeForMarkdown(indented))).toBe('foo\n&#32;&#32;&#32;bar');
    // The break itself now reads as a newline, which is what makes a plain-text
    // copy of a paragraph keep its line breaks.
    expect(parseMarkdown('foo\n&#32;&#32;&#32;bar').textContent).toBe('foo\n   bar');
  });

  it('drops a space at the very start of a block, which is an editing artifact', () => {
    // Splitting "bold text" after the word leaves the next paragraph starting with
    // a space; nobody typed it on purpose and writing it out means a leading entity.
    expect(serializeMarkdown(normalizeForMarkdown(doc(p(t('   foo')))))).toBe('foo');
  });

  it('drops a trailing space rather than writing an entity nobody wants to read', () => {
    expect(serializeMarkdown(normalizeForMarkdown(doc(p(t('foo ')))))).toBe('foo');
    expect(serializeMarkdown(normalizeForMarkdown(doc(p(t('foo  '), soft(), t('bar')))))).toBe('foo\nbar');
  });

  it('does not leave an unrepresentable break pair behind when a line goes empty', () => {
    // Trimming " " out of `foo⏎ ⏎bar` would put two soft breaks together, which is
    // a blank line and ends the paragraph.
    const input = doc(p(t('foo'), soft(), t('  '), soft(), t('bar')));
    expectNormalized(input, 'foo\nbar');
    expect(normalizeForMarkdown(input).firstChild?.childCount).toBe(3);
  });
});

describe('empty and near-empty blocks the keyboard can reach', () => {
  const item = (...content: ProseNode[]) => S.node('list_item', null, content);

  it('drops an empty paragraph between two others', () => {
    // Pressing Enter twice. A blank line SEPARATES paragraphs in markdown, it is
    // not a paragraph, so this leaves no trace in storage — and it needs none: the
    // gap the user wanted is already there, from paragraph spacing.
    expectNormalized(doc(p(t('a')), p(), p(t('b'))), 'a\n\nb');
  });

  it('drops several empty paragraphs', () => {
    expectNormalized(doc(p(t('a')), p(), p(), p(), p(t('b'))), 'a\n\nb');
  });

  it('drops a trailing empty paragraph', () => {
    expectNormalized(doc(p(t('a')), p()), 'a');
  });

  it('keeps a document that is nothing but an empty paragraph', () => {
    // The schema requires block+, so there is nothing to drop it in favour of.
    expectClosed(doc(p()));
  });

  // Each of these IS representable, so it must survive untouched — the empty
  // paragraph rule must not reach in and delete a block's only child.
  it('keeps an empty heading', () => {
    expectClosed(doc(S.node('heading', { level: 2 }, [])));
    expect(serializeMarkdown(doc(S.node('heading', { level: 2 }, [])))).toBe('## ');
  });
  it('keeps an empty blockquote', () => {
    expectClosed(doc(S.node('blockquote', null, [p()])));
    expect(serializeMarkdown(doc(S.node('blockquote', null, [p()])))).toBe('> ');
  });
  it('keeps an empty code block', () => expectClosed(doc(S.node('code_block', { params: '' }, []))));
  it('keeps an empty bullet item', () => {
    expectClosed(doc(S.node('bullet_list', { tight: true }, [item(p())])));
    expect(serializeMarkdown(doc(S.node('bullet_list', { tight: true }, [item(p())])))).toBe('* ');
  });
  it('keeps an empty ordered item', () => {
    const list = doc(S.node('ordered_list', { order: 3, tight: true }, [item(p())]));
    expectClosed(list);
    expect(serializeMarkdown(list)).toBe('3. ');
  });

  // An empty item in each position, because a first, middle and last one are three
  // different jobs for the serializer.
  const filled = (text: string) => item(p(t(text)));
  it('keeps an empty FIRST list item', () => expectClosed(
    doc(S.node('bullet_list', { tight: true }, [item(p()), filled('b'), filled('c')])),
  ));
  it('keeps an empty MIDDLE list item', () => expectClosed(
    doc(S.node('bullet_list', { tight: true }, [filled('a'), item(p()), filled('c')])),
  ));
  it('keeps an empty LAST list item', () => expectClosed(
    doc(S.node('bullet_list', { tight: true }, [filled('a'), filled('b'), item(p())])),
  ));

  it('keeps a paragraph that is nothing but a hard break', () => {
    // Reachable: Shift+Enter into an empty paragraph. The break has nothing to
    // separate, so it goes, and the empty paragraph is then the only child.
    expectNormalized(doc(p(t('a')), p(hard()), p(t('b'))), 'a\n\nb');
  });

  it('drops an empty paragraph beside content inside a blockquote', () => {
    expectNormalized(doc(S.node('blockquote', null, [p(t('q')), p()])), '> q');
  });

  it('keeps the sole empty paragraph of a blockquote', () => {
    expectClosed(doc(S.node('blockquote', null, [p()])));
  });

  it('drops an empty paragraph inside a list item that has other content', () => {
    expectNormalized(
      doc(S.node('bullet_list', { tight: true }, [item(p(t('a')), p()), item(p(t('b')))])),
      '* a\n* b',
    );
  });
});

describe('inline code at its edges', () => {
  const codeMark = S.marks.code.create();
  it('moves flanking whitespace outside the marker', () => {
    // CommonMark strips one space from each end of `` ` x ` ``, so the spaces
    // cannot live inside the code span.
    expectNormalized(doc(p(t('a'), S.text(' x ', [codeMark]), t('b'))), 'a `x` b');
  });
  it('drops a code mark that covers nothing but spaces', () => {
    expectNormalized(doc(p(t('a'), S.text('   ', [codeMark]), t('b'))), 'a   b');
  });
  it('drops a code mark on a single space', () => {
    expectNormalized(doc(p(t('a'), S.text(' ', [codeMark]), t('b'))), 'a b');
  });
  it('keeps interior whitespace', () => expectClosed(doc(p(S.text('a  b', [codeMark])))));

  it('expels at the edges of a RUN, not of each text node', () => {
    // A code run split across two text nodes — a link boundary does it — must keep
    // the whitespace that is interior to the run.
    const link = S.marks.link.create({ href: 'https://x.test', title: null });
    const input = doc(p(t('x'), S.text(' a ', [codeMark]), S.text(' b ', [codeMark, link]), t('y')));
    // Two code spans, because the link has to open between them — and closed, which
    // is what matters: the whitespace interior to the run is still there.
    expectNormalized(input, 'x `a `[` b` ](https://x.test)y');
  });

  it('cannot be combined with formatting markdown would render literally', () => {
    // `<u>b</u>` inside a code span shows the tags. The schema forbids the
    // combination so the selection menu cannot build it in the first place.
    const marks = S.marks.underline.create().addToSet([S.marks.code.create()]);
    expect(marks.map((mark) => mark.type.name)).toEqual(['code']);
    expect(S.marks.code.create().addToSet([S.marks.underline.create()]).map((m) => m.type.name)).toEqual(['code']);
  });
});

describe('attributes markdown cannot spell', () => {
  const item = (text: string) => S.node('list_item', null, [p(t(text))]);

  it('clamps a negative ordered-list start', () => {
    // Reachable by pasting <ol start="-1"> from a web page. Serialised as `-1.` it
    // reloads as a paragraph, taking the whole list with it.
    expectNormalized(doc(S.node('ordered_list', { order: -1, tight: true }, [item('a')])), '0. a');
  });

  it('clamps a start whose LATER items would overflow', () => {
    // The last marker matters as much as the first: two items from 999999999 puts a
    // ten-digit number on item two.
    expectNormalized(
      doc(S.node('ordered_list', { order: 999999999, tight: true }, [item('a'), item('b')])),
      '999999998. a\n999999999. b',
    );
  });

  it('keeps the largest start that still fits', () => {
    expectClosed(doc(S.node('ordered_list', { order: 999999999, tight: true }, [item('a')])));
  });

  it('clamps a heading level above 6', () => {
    // `####### x` is not a heading in CommonMark; it reloads as plain text.
    expectNormalized(doc(S.node('heading', { level: 7 }, [t('x')])), '###### x');
  });

  it('clamps a heading level below 1', () => expectNormalized(doc(S.node('heading', { level: 0 }, [t('x')])), '# x'));
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
  it('bold around leading and trailing spaces moves them outside the marker', () => {
    // `** b **` is not emphasis at all in markdown, so the spaces must sit outside.
    expectNormalized(doc(p(t('a'), S.text(' b ', [bold]), t('c'))), 'a **b** c');
  });
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
    // The bold no longer covers the flanking spaces; the block edges then drop them.
    expectNormalized(input, '**X1 — [link](https://x.test)**');
    expect(normalizeForMarkdown(input).textContent).toBe('X1 — link');
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

  it('keeps looseness when a LATER item carries it', () => {
    // The signal is the hidden flag on a paragraph that is a DIRECT child of some
    // item. Here the first item has only a blockquote, but the second has a
    // paragraph, so the looseness survives and must not be flattened.
    const loose = doc(S.node('bullet_list', { tight: false }, [quoteItem(), item('p')]));
    expect(normalizeForMarkdown(loose).firstChild?.attrs.tight).toBe(false);
    expect(serializeMarkdown(normalizeForMarkdown(loose))).toBe('* > q\n\n* p');
    expectClosed(loose);
  });

  it('only flattens a list where NO item could carry looseness', () => {
    const nowhere = doc(S.node('bullet_list', { tight: false }, [codeItem(), quoteItem()]));
    expectNormalized(nowhere, '* ```\n  x\n  ```\n* > q');
    expect(normalizeForMarkdown(nowhere).firstChild?.attrs.tight).toBe(true);
  });
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
  // Already in the form markdown gives back, so they survive untouched.
  const canonical = ['https://x.test/a(b)', 'https://x.test/?q=a%20quote&r=1', 'ticker-pdf://s?page=3&q=a%20quote', 'ticker-asset://s/a.png', '#anchor', ''];
  for (const href of canonical) it(JSON.stringify(href), () => expectClosed(linked(href)));

  // markdown-it percent-encodes a destination on the way in, so an href the editor
  // invented is rewritten to the form it will come back as. A space is the sharp
  // case: it ENDS a destination, so without this the link vanishes entirely.
  const rewritten: Array<[string, string]> = [
    ['https://x.test/a b', '[text](https://x.test/a%20b)'],
    ['https://x.test/a<b>c', '[text](https://x.test/a%3Cb%3Ec)'],
    ['https://x.test/a"b', '[text](https://x.test/a%22b)'],
    ['https://exämple.test/ä', '[text](https://xn--exmple-cua.test/%C3%A4)'],
  ];
  for (const [href, markdown] of rewritten) {
    it(`canonicalises ${JSON.stringify(href)}`, () => expectNormalized(linked(href), markdown));
  }

  it('drops a link markdown would refuse rather than storing a dead one', () => {
    const doomed = linked('javascript:alert(1)');
    expectNormalized(doomed, 'text'); // the words are kept, the link is not
    const normalized = normalizeForMarkdown(doomed);
    expect(normalized.rangeHasMark(0, normalized.content.size, S.marks.link)).toBe(false);
  });
});

describe('text that markdown would decode', () => {
  // Entities are the one thing markdown rewrites SILENTLY and stably: written out
  // untouched, a literal "&amp;" reloads as "&", "&#32;" as a space, "&copy;" as ©.
  // Nothing about the round-trip looks broken; the text is just quietly different.
  const literals = ['&amp;', '&#32;', '&copy;', '&#x41;', 'a &amp; b', '&notanentity', 'AT&T', 'a & b', '&&&'];
  for (const text of literals) it(JSON.stringify(text), () => expectClosed(doc(p(t(text)))));

  it('leaves ordinary ampersands unescaped, so the markdown stays readable', () => {
    expect(serializeMarkdown(doc(p(t('AT&T and a & b'))))).toBe('AT&T and a & b');
  });

  it('escapes only real entity syntax', () => {
    expect(serializeMarkdown(doc(p(t('a &amp; b'))))).toBe('a \\&amp; b');
  });

  it('survives inside every attribute markdown writes raw', () => {
    const link = S.marks.link.create({ href: 'https://x.test/?a=&amp;b', title: 'a &copy; t' });
    expectClosed(doc(p(S.text('label', [link]))));
    expectClosed(doc(p(S.node('image', {
      src: 'ticker-asset://s/a&amp;b.png', alt: 'an &amp; alt', title: 'a &copy; title', width: null,
    }))));
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
