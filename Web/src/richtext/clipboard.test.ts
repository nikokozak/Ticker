// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { DOMParser, DOMSerializer, type Node as ProseNode } from 'prosemirror-model';
import { parseMarkdown } from './markdown';
import { tickerSchema as S } from './schema';

/**
 * Copy/paste INSIDE the editor is a second, independent codec, and it is easy to
 * forget: ProseMirror puts the slice on the clipboard as HTML and parses HTML back,
 * even for a same-editor paste. Anything a node's `toDOM` omits, or its `parseDOM`
 * cannot read, is silently gone the moment a user copies a paragraph.
 *
 * So the markdown closure gate has a twin:
 *
 *     doc.eq(parseDOM(serializeDOM(doc)))
 *
 * The hand-written schema this replaced failed five of these.
 */

function throughClipboard(doc: ProseNode): ProseNode {
  const dom = DOMSerializer.fromSchema(S).serializeFragment(doc.content, { document });
  const holder = document.createElement('div');
  holder.appendChild(dom);
  return DOMParser.fromSchema(S).parse(holder);
}

function expectSurvives(markdown: string): void {
  const doc = parseMarkdown(markdown);
  const back = throughClipboard(doc);
  expect(back.eq(doc), `copy/paste changed the document.\n  before: ${doc.toString()}\n  after:  ${back.toString()}`).toBe(true);
}

describe('a document survives its own clipboard', () => {
  const cases: Array<[string, string]> = [
    ['plain paragraph', 'hello there'],
    ['heading', '## Title'],
    ['bold, italic, code', 'a **b** *c* `d`'],
    ['underline', 'a <u>b</u> c'],
    ['nested marks', '***both*** and <u>**u-bold**</u>'],
    ['link', '[text](https://example.test)'],
    ['citation link', '[Book p.3](ticker-pdf://s?page=3&q=a%20quote)'],
    ['blockquote', '> quoted'],
    ['horizontal rule', 'a\n\n---\n\nb'],
    ['code block with info string', '```ts\nconst x = 1;\n```'],
    ['code block without info string', '```\nplain\n```'],
    ['tight bullet list', '* one\n* two'],
    ['loose bullet list', '* one\n\n* two'],
    ['ordered list starting at 1', '1. one\n2. two'],
    ['ordered list starting at 7', '7. seven\n8. eight'],
    ['nested list', '* one\n  * inner\n* two'],
    ['image', '![alt](ticker-asset://s/a.png)'],
    ['image with width', '![alt](ticker-asset://s/a.png){width=300}'],
    ['soft break', 'one\ntwo'],
    ['hard break', 'one\\\ntwo'],
  ];
  for (const [name, markdown] of cases) it(name, () => expectSurvives(markdown));
});

describe('the attributes that a hand-written schema drops', () => {
  it('keeps a code block info string', () => {
    expect(throughClipboard(parseMarkdown('```ts\nx\n```')).firstChild?.attrs.params).toBe('ts');
  });

  it('keeps an ordered list start', () => {
    expect(throughClipboard(parseMarkdown('7. seven')).firstChild?.attrs.order).toBe(7);
  });

  it('keeps list tightness in both directions', () => {
    expect(throughClipboard(parseMarkdown('* a\n* b')).firstChild?.attrs.tight).toBe(true);
    expect(throughClipboard(parseMarkdown('* a\n\n* b')).firstChild?.attrs.tight).toBe(false);
  });

  it('keeps an image width', () => {
    const img = throughClipboard(parseMarkdown('![a](ticker-asset://s/a.png){width=300}')).firstChild?.firstChild;
    expect(img?.attrs.width).toBe(300);
  });

  it('keeps a soft break distinct from a hard break', () => {
    // Both render as <br>; the stock hard_break rule matches any <br>, so without a
    // priority on the soft-break rule a copied line break changes kind on paste.
    const kinds = (markdown: string) => {
      const names: string[] = [];
      throughClipboard(parseMarkdown(markdown)).descendants((node) => { names.push(node.type.name); });
      return names;
    };
    expect(kinds('one\ntwo')).toContain('soft_break');
    expect(kinds('one\ntwo')).not.toContain('hard_break');
    expect(kinds('one\\\ntwo')).toContain('hard_break');
  });
});

describe('pasted foreign HTML cannot smuggle in an image width', () => {
  const parse = (html: string) => {
    const holder = document.createElement('div');
    holder.innerHTML = html;
    return DOMParser.fromSchema(S).parse(holder);
  };
  const widthOf = (html: string) => parse(html).firstChild?.firstChild?.attrs.width;

  it('ignores width on a non-asset image', () => {
    expect(widthOf('<p><img src="https://example.test/a.png" width="800"></p>')).toBe(null);
  });

  it('ignores an out-of-range width on an asset image', () => {
    expect(widthOf('<p><img src="ticker-asset://s/a.png" width="5000"></p>')).toBe(null);
    expect(widthOf('<p><img src="ticker-asset://s/a.png" width="10"></p>')).toBe(null);
  });

  it('accepts an in-range width on an asset image', () => {
    expect(widthOf('<p><img src="ticker-asset://s/a.png" width="300"></p>')).toBe(300);
  });
});
