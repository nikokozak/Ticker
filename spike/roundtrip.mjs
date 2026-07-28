// Phase 1 of the rich-text spike: does the serializer define a STABLE canonical form?
//
// Everything in option C rests on this. If `canonical = S(P(raw))` and
// `S(P(canonical)) === canonical`, then a one-time rewrite of every document to
// serializer output makes every stored markdown offset an offset into serializer
// output by construction — and because serialising a canonical document
// reproduces it exactly, the serializer's own source map gives offset <-> position
// in BOTH directions for free. No parser source map is ever needed.
//
// If it does not converge, that whole plan is dead and nothing else matters, so
// this is measured before a single line of schema or UI is written.
//
// Deliberately run against the DEFAULT schema first: the point is to find out
// which custom nodes/marks Ticker actually needs, not to guess them up front.
import { readFileSync } from 'node:fs';
import { defaultMarkdownParser, defaultMarkdownSerializer } from 'prosemirror-markdown';

const parse = (md) => defaultMarkdownParser.parse(md);
const serialize = (doc) => defaultMarkdownSerializer.serialize(doc);

/** Things that must survive verbatim or Ticker breaks, independent of formatting. */
const LOAD_BEARING = [
  ['ticker-pdf url', /ticker-pdf:\/\/[^\s)]+/g],
  ['ticker-asset url', /ticker-asset:\/\/[^\s)]+/g],
  ['image width attr', /\{width=\d+\}/g],
  ['underline tag', /<\/?u\s*>/gi],
];

/**
 * Byte survival is NOT fidelity. `<u>keyword</u>` round-trips exactly while
 * parsing to `paragraph > text` — the tags are literal characters, so underline
 * is gone as a concept AND the user would see the markup. Counting occurrences
 * reported that as a pass, which is precisely the false green this spike exists
 * to catch. So: if the source contains a construct, the parsed document must
 * contain a node or mark that MEANS it.
 */
const FIDELITY = [
  ['heading', /^#{1,6} /m, 'heading'],
  ['bold', /(^|[^\\])\*\*[^*\n]+\*\*/, 'strong'],
  ['italic', /(^|[^*\\])\*[^*\n]+\*/, 'em'],
  ['inline code', /`[^`\n]+`/, 'code'],
  ['code block', /^```|^ {4}\S/m, 'code_block'],
  ['bullet list', /^[-*+] /m, 'bullet_list'],
  ['ordered list', /^\d+\. /m, 'ordered_list'],
  ['blockquote', /^> /m, 'blockquote'],
  ['link', /(^|[^!])\[[^\]\n]*\]\([a-z-]+:\/\//, 'link'],
  ['image', /!\[[^\]]*\]\(/, 'image'],
  ['table', /^\|.*\|\s*$/m, 'table'],
  ['strikethrough', /~~[^~\n]+~~/, 'strikethrough'],
  ['underline', /<u\s*>/i, 'underline'],
  ['task list', /^[-*] \[[ xX]\]/m, 'task_item'],
];

function typesIn(doc) {
  const found = new Set();
  doc.descendants((node) => {
    found.add(node.type.name);
    for (const mark of node.marks) found.add(mark.type.name);
  });
  return found;
}

/** Constructs present in the source that the document has no way to represent. */
function degraded(raw, doc) {
  const present = typesIn(doc);
  return FIDELITY.filter(([, re, type]) => re.test(raw) && !present.has(type)).map(([name]) => name);
}

// Constructs absent from the 23 real documents but certain to appear later. A
// corpus this small passing proves very little on its own.
const SYNTHETIC = {
  'astral chars': 'A 🧠 and a 👨‍👩‍👧 family, **bold 🎯 here**.',
  'combining marks': 'Café vs Café — **both** forms.',
  'link title': '[label](https://x.com "the title") here.',
  'escapes': 'Literal \\*not italic\\* and \\[not a link\\].',
  'setext heading': 'Title\n=====\n\nBody text.',
  'strikethrough': 'This is ~~struck~~ text.',
  'task list': '- [ ] todo\n- [x] done',
  'table': '| a | b |\n|---|---|\n| 1 | 2 |',
  'nested quote+list': '> - one\n>   - two\n>\n> after',
  'html block': '<div class="x">\nraw\n</div>',
  'underline': 'a <u>keyword</u> here',
  'image width': '![shot](ticker-asset://s/a.png){width=300}',
  'citation': 'see [Book p.3](ticker-pdf://abc?page=3&q=a%20quote) here',
  'hard break': 'line one  \nline two',
  'indented code': 'text\n\n    indented\n    code\n',
  'bare url': 'visit https://example.com/x?y=1 now',
  'emphasis underscore': '_italic_ and __bold__ forms',
};

function classify(before, after) {
  if (before === after) return null;
  for (let i = 0; i < Math.min(before.length, after.length); i += 1) {
    if (before[i] !== after[i]) {
      return { at: i, before: JSON.stringify(before.slice(i, i + 40)), after: JSON.stringify(after.slice(i, i + 40)) };
    }
  }
  return { at: Math.min(before.length, after.length), before: JSON.stringify(before.slice(-40)), after: JSON.stringify(after.slice(-40)) };
}

function lossReport(raw, canonical) {
  const lost = [];
  for (const [name, re] of LOAD_BEARING) {
    const a = (raw.match(re) ?? []).length;
    const b = (canonical.match(re) ?? []).length;
    if (a !== b) lost.push(`${name}: ${a} -> ${b}`);
  }
  return lost;
}

function check(label, raw) {
  let canonical;
  let doc;
  try {
    doc = parse(raw);
    canonical = serialize(doc);
  } catch (error) {
    return { label, status: 'PARSE/SERIALIZE THREW', detail: String(error).slice(0, 120) };
  }

  let again;
  try {
    again = serialize(parse(canonical));
  } catch (error) {
    return { label, status: 'SECOND PASS THREW', detail: String(error).slice(0, 120) };
  }

  const lost = lossReport(raw, canonical);
  const flattened = degraded(raw, doc);
  const stable = again === canonical;
  const status = !stable ? 'NOT IDEMPOTENT'
    : flattened.length ? 'MEANING LOST'
    : lost.length ? 'BYTES LOST'
    : raw === canonical ? 'EXACT'
    : 'CANONICALIZED';
  return {
    label,
    status,
    detail: !stable ? JSON.stringify(classify(canonical, again))
      : flattened.length ? `flattened to text: ${flattened.join(', ')}`
      : lost.join('; '),
  };
}

const corpus = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const results = [
  ...corpus.map((row, i) => check(`real#${i} (${(row.markdown ?? '').length}c)`, row.markdown ?? '')),
  ...Object.entries(SYNTHETIC).map(([name, md]) => check(`synth: ${name}`, md)),
];

const byStatus = new Map();
for (const r of results) byStatus.set(r.status, (byStatus.get(r.status) ?? 0) + 1);

console.log('=== summary ===');
for (const [status, n] of [...byStatus].sort((a, b) => b[1] - a[1])) console.log(String(n).padStart(3), status);
console.log('\n=== everything that is not EXACT ===');
for (const r of results.filter((x) => x.status !== 'EXACT')) {
  console.log(`${r.status.padEnd(18)} ${r.label.padEnd(28)} ${r.detail}`);
}

// Idempotence is the gate. Data loss tells us which custom schema pieces to build.
const unstable = results.filter((r) => r.status.includes('THREW') || r.status === 'NOT IDEMPOTENT');
const lossy = results.filter((r) => r.status === 'MEANING LOST' || r.status === 'BYTES LOST');
console.log(`\nGATE 1 (canonical form converges): ${unstable.length === 0 ? 'PASS' : `FAIL — ${unstable.length} never converge`}`);
console.log(`GATE 2 (no construct flattened):    ${lossy.length === 0 ? 'PASS' : `FAIL — ${lossy.length} lose meaning`}`);
