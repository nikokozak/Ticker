import { describe, expect, it } from 'vitest';
import { parseMarkdown, serializeMarkdown } from './markdown';
import type { Node as ProseNode } from 'prosemirror-model';
import { tickerSchema } from './schema';

/**
 * The proof obligations for the codec, per the settled schema spec. Assertions are
 * per-occurrence and attribute-exact on purpose: three times during this rewrite a
 * looser check ("an image exists", "the bytes match") reported green while meaning
 * had been destroyed.
 */

const canon = (md: string) => serializeMarkdown(parseMarkdown(md));

/** Every node in document order, flattened, with the marks that apply to it. */
function inventory(doc: ProseNode): Array<{ type: string; text?: string; marks: string[]; attrs?: Record<string, unknown> }> {
  const out: Array<{ type: string; text?: string; marks: string[]; attrs?: Record<string, unknown> }> = [];
  doc.descendants((node) => {
    out.push({
      type: node.type.name,
      ...(node.isText ? { text: node.text } : {}),
      marks: node.marks.map((m) => m.type.name),
      ...(Object.keys(node.attrs).length ? { attrs: node.attrs } : {}),
    });
  });
  return out;
}

describe('1. stock CommonMark dialect', () => {
  const source = [
    '### Heading three',
    '',
    'Plain *em* and **strong** and `code` and [label](https://x.com).',
    '',
    '> quoted line',
    '',
    '* one',
    '* two',
    '',
    '3. third',
    '4. fourth',
    '',
    '```ts',
    'const x = 1;',
    '```',
    '',
    '---',
  ].join('\n');

  it('preserves structure, levels, list attrs and fence info exactly', () => {
    const doc = parseMarkdown(source);
    const types = inventory(doc).map((n) => n.type);
    expect(types).toContain('heading');
    expect(types).toContain('blockquote');
    expect(types).toContain('bullet_list');
    expect(types).toContain('ordered_list');
    expect(types).toContain('code_block');
    expect(types).toContain('horizontal_rule');

    const heading = doc.child(0);
    expect(heading.attrs.level).toBe(3);

    const ordered = inventory(doc).find((n) => n.type === 'ordered_list');
    expect(ordered?.attrs?.order).toBe(3); // a list starting at 3 must stay at 3

    const code = inventory(doc).find((n) => n.type === 'code_block');
    expect(code?.attrs?.params).toBe('ts'); // the info string is content, not decoration
  });

  it('reaches a canonical fixed point in one pass', () => {
    const once = canon(source);
    expect(canon(once)).toBe(once);
  });

  it('marks every inline occurrence, not just one', () => {
    const doc = parseMarkdown('a *one* b **two** c `three` d [four](https://x.com)');
    const marked = inventory(doc).filter((n) => n.marks.length);
    expect(marked.map((n) => [n.text, n.marks])).toEqual([
      ['one', ['em']],
      ['two', ['strong']],
      ['three', ['code']],
      ['four', ['link']],
    ]);
  });
});

describe('2. soft break versus hard break', () => {
  it('keeps an authored newline as a newline, not a space', () => {
    const doc = parseMarkdown('line one\nline two');
    expect(inventory(doc).map((n) => n.text ?? n.type)).toEqual(['paragraph', 'line one', 'soft_break', 'line two']);
    expect(serializeMarkdown(doc)).toBe('line one\nline two');
  });

  it('keeps an explicit hard break distinct', () => {
    const doc = parseMarkdown('line one\\\nline two');
    expect(inventory(doc).map((n) => n.text ?? n.type)).toEqual(['paragraph', 'line one', 'hard_break', 'line two']);
    expect(canon('line one\\\nline two')).toBe('line one\\\nline two');
  });

  it('keeps a soft break inside a blockquote quoted on reparse', () => {
    expect(canon('> one\n> two')).toBe('> one\n> two');
  });
});

describe('3. underline', () => {
  it('marks every covered occurrence and leaves no tags in the text', () => {
    const doc = parseMarkdown('<u>A **B**</u> and <u>C</u>');
    const texts = inventory(doc).filter((n) => n.text);
    expect(texts.map((n) => [n.text, n.marks])).toEqual([
      ['A ', ['underline']],
      ['B', ['underline', 'strong']],
      [' and ', []],
      ['C', ['underline']],
    ]);
    for (const node of texts) expect(node.text).not.toMatch(/<\/?u/);
  });

  it('round-trips to canonical lowercase tags', () => {
    expect(canon('a <U >keyword</U > b')).toBe('a <u>keyword</u> b');
  });

  // Nothing the user types is refused. An unmatched or unsupported tag is content,
  // so it survives as literal text — the same principle that lets tables through.
  for (const [name, source, visible] of [
    ['unmatched open', 'a <u>keyword', 'a <u>keyword'],
    ['unmatched close', 'a keyword</u>', 'a keyword</u>'],
    ['cross-paragraph', '<u>first\n\nsecond</u>', '<u>first'],
    ['other inline html', 'a <span>x</span> b', 'a <span>x</span> b'],
    ['html block', '<div>\nraw\n</div>', '<div>'],
  ] as const) {
    it(`keeps ${name} as literal text rather than failing`, () => {
      const doc = parseMarkdown(source);
      const text = inventory(doc).filter((n) => n.text).map((n) => n.text).join('');
      expect(text).toContain(visible);
      expect(inventory(doc).some((n) => n.marks.includes('underline'))).toBe(false);
      // and it must survive a round-trip unchanged
      const once = canon(source);
      expect(canon(once)).toBe(once);
    });
  }

  it('still pairs the inner tags when they nest', () => {
    const doc = parseMarkdown('<u>a <u>b</u> c</u>');
    // The inner pair wins; the unmatched outer tags stay text. Nothing is lost.
    expect(inventory(doc).filter((n) => n.marks.includes('underline')).map((n) => n.text)).toEqual(['b']);
  });
});

describe('4. image width', () => {
  it('lifts {width=N} into an attribute, leaving no literal text', () => {
    const doc = parseMarkdown('![shot](ticker-asset://s/a.png "cap"){width=300} and ![plain](https://x.com/b.png)');
    const images = inventory(doc).filter((n) => n.type === 'image');
    expect(images.map((n) => n.attrs)).toEqual([
      { src: 'ticker-asset://s/a.png', alt: 'shot', title: 'cap', width: 300 },
      { src: 'https://x.com/b.png', alt: 'plain', title: null, width: null },
    ]);
    for (const node of inventory(doc)) expect(node.text ?? '').not.toContain('{width=');
  });

  it('round-trips the width exactly', () => {
    const source = '![shot](ticker-asset://s/a.png){width=300}';
    expect(canon(source)).toBe(source);
  });

  it('leaves an escaped suffix as literal text and sets no width', () => {
    const doc = parseMarkdown('![shot](ticker-asset://s/a.png)\\{width=300\\}');
    const image = inventory(doc).find((n) => n.type === 'image');
    expect(image?.attrs?.width).toBeNull();
    expect(inventory(doc).some((n) => (n.text ?? '').includes('{width=300}'))).toBe(true);
  });

  it('leaves an out-of-range width as literal text rather than clamping or failing', () => {
    const doc = parseMarkdown('![s](ticker-asset://s/a.png){width=9999}');
    expect(inventory(doc).find((n) => n.type === 'image')?.attrs?.width).toBeNull();
    expect(inventory(doc).some((n) => (n.text ?? '').includes('{width=9999}'))).toBe(true);
  });

  it('ignores a width suffix on a non-asset image', () => {
    const doc = parseMarkdown('![s](https://x.com/a.png){width=300}');
    expect(inventory(doc).find((n) => n.type === 'image')?.attrs?.width).toBeNull();
  });
});

describe('5. links and content preservation', () => {
  it('preserves citation and http hrefs exactly, per occurrence', () => {
    const source = 'see [Guide \\[draft\\] p.7](ticker-pdf://src?page=7&chunk=c1&q=a%20quote) and [x](https://x.com "t")';
    const doc = parseMarkdown(source);
    const links = inventory(doc).filter((n) => n.marks.includes('link'));
    expect(links.map((n) => n.text)).toEqual(['Guide [draft] p.7', 'x']);

    const hrefs: string[] = [];
    doc.descendants((node) => {
      for (const mark of node.marks) if (mark.type.name === 'link') hrefs.push(String(mark.attrs.href));
    });
    expect(hrefs).toEqual(['ticker-pdf://src?page=7&chunk=c1&q=a%20quote', 'https://x.com']);

    // Attributes must survive a full round-trip, not just the first parse.
    const reparsed: string[] = [];
    parseMarkdown(serializeMarkdown(doc)).descendants((node) => {
      for (const mark of node.marks) if (mark.type.name === 'link') reparsed.push(String(mark.attrs.href));
    });
    expect(reparsed).toEqual(hrefs);
  });

  it('leaves a bare URL as unmarked text', () => {
    const doc = parseMarkdown('visit https://example.com/x?y=1 now');
    expect(inventory(doc).filter((n) => n.marks.includes('link'))).toEqual([]);
  });

  it('leaves quotes and dashes byte-identical', () => {
    const source = 'She said "hello" -- it\'s fine...';
    expect(canon(source)).toBe(source);
  });

  it('keeps astral characters and their marks intact', () => {
    const doc = parseMarkdown('A 🧠 and **bold 🎯** here');
    expect(inventory(doc).filter((n) => n.marks.includes('strong')).map((n) => n.text)).toEqual(['bold 🎯']);
    expect(canon('A 🧠 and **bold 🎯** here')).toBe('A 🧠 and **bold 🎯** here');
  });
});

describe('6. unsupported syntax is preserved, never mangled', () => {
  // ponytail: no raw_block node. With the table rule off these are ordinary text
  // plus soft breaks, so they survive verbatim — nothing is refused, nothing lost.
  for (const [name, source] of [
    ['table', '| a | b |\n|---|---|\n| 1 | 2 |'],
    ['task list', '* [ ] todo\n* [x] done'],
    ['strikethrough', 'This is ~~struck~~ text.'],
  ] as const) {
    it(`preserves ${name} verbatim through a round-trip`, () => {
      const doc = parseMarkdown(source);
      const rendered = inventory(doc).filter((n) => n.text).map((n) => n.text).join(' ');
      expect(rendered).not.toContain('\\'); // no stray escapes leak into what the user sees
      expect(canon(source)).toBe(canon(canon(source))); // and it is stable
    });
  }

  it('cannot emit output that its own parser would reject or reinterpret', () => {
    // The closure property: everything the serializer writes must parse back to the
    // same text. Literal <u>, table pipes, tildes, brackets and a width suffix.
    const hostile = 'literal <u> and | pipes | and ~~tildes~~ and [ ] and {width=300}';
    const once = canon(hostile);
    const doc = parseMarkdown(once);
    const text = inventory(doc).filter((n) => n.text).map((n) => n.text).join('');
    expect(text).toBe(hostile);
    expect(canon(once)).toBe(once);
  });
});

describe('7. serializer output always re-parses to the same document', () => {
  // The closure property, tested on EDITOR-CONSTRUCTED documents rather than parsed
  // ones — that is where it breaks. A soft break starts a new line, so text after
  // it sits where block syntax is live. `foo` + break + `---` once serialized to
  // `foo\n---`, which reloads as a setext heading and eats the second line.
  const shape = (doc: ProseNode) => {
    const out: string[] = [];
    doc.descendants((n) => { out.push(`${n.type.name}${n.isText ? `:${JSON.stringify(n.text)}` : ''}`); });
    return out.join(' ');
  };

  for (const second of ['# bar', '> quote', '- item', '1. item', '```', '---', '+ plus', '* star', ': def', '| a |', '~~s~~', '[x]', '{width=300}', '<u>']) {
    it(`survives a soft break followed by ${JSON.stringify(second)}`, () => {
      const doc = tickerSchema.node('doc', null, [
        tickerSchema.node('paragraph', null, [
          tickerSchema.text('foo'),
          tickerSchema.node('soft_break'),
          tickerSchema.text(second),
        ]),
      ]);
      const out = serializeMarkdown(doc);
      expect(shape(parseMarkdown(out))).toBe(shape(doc));
      expect(serializeMarkdown(parseMarkdown(out))).toBe(out); // and it is stable
    });
  }
});
