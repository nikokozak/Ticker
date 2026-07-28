// Settling the ingress/mapping question BEFORE building phase 2.
//
// Codex is right that a serializer cannot manufacture raw-markdown-offset -> PM
// position, and right that mapping by searching for the covered text is unsafe
// ("alpha ... alpha" maps to the wrong occurrence and passes both equality and
// hash). But there is a third option it did not consider: do not search, CONSUME.
//
// Canonicalisation rewrites syntax, never content. So the document's text nodes
// appear, in order, in both the old and the canonical markdown. Walking them with
// a single non-rewinding cursor makes duplicates unambiguous by construction: the
// Nth occurrence is claimed by the Nth text node, never by a search.
//
// If every text node can be located this way in every real document, the mapping
// is well defined for all CONTENT positions, and only delimiter-interior endpoints
// need an affinity policy. If alignment fails, phase 2's design changes shape.
import { readFileSync } from 'node:fs';
import { defaultMarkdownParser, defaultMarkdownSerializer } from 'prosemirror-markdown';

/** Text nodes in document order, with their ProseMirror positions. */
function textNodes(doc) {
  const out = [];
  doc.descendants((node, pos) => {
    if (node.isText && node.text) out.push({ pos, text: node.text });
  });
  return out;
}

/**
 * A text node is not a literal substring of its source. Two systematic reasons,
 * both found by measurement rather than guessed:
 *   - a single newline inside a paragraph is a markdown SOFT BREAK and arrives in
 *     the text node as a space (plus any block prefix: list indent, '> ');
 *   - the serializer escapes syntax characters, so source `\[x\]` is text `[x]`.
 * So match tolerantly, still consuming strictly forward. Returns the end offset,
 * or -1 if the text does not start here.
 */
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0' };

/** `&amp;` in source is `&` in the text node. Returns [decoded, consumedLength] or null. */
function entityAt(markdown, m) {
  const match = /^&(#\d{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});/.exec(markdown.slice(m, m + 34));
  if (!match) return null;
  const body = match[1];
  const decoded = body[0] === '#'
    ? String.fromCodePoint(Number(body[1] === 'x' || body[1] === 'X' ? `0${body.slice(1)}` : body.slice(1)))
    : ENTITIES[body];
  return decoded === undefined ? null : [decoded, match[0].length];
}

function matchAt(markdown, text, start) {
  let m = start;
  let t = 0;
  while (t < text.length) {
    if (m >= markdown.length) return -1;
    const mc = markdown[m];
    const tc = text[t];
    if (mc === '\\' && m + 1 < markdown.length && markdown[m + 1] === tc) { m += 2; t += 1; continue; }
    if (mc === '&') {
      const entity = entityAt(markdown, m);
      if (entity && text.startsWith(entity[0], t)) { m += entity[1]; t += entity[0].length; continue; }
    }
    if (mc === '\r' && markdown[m + 1] === '\n' && tc === ' ') {
      m += 2;
      while (m < markdown.length && (markdown[m] === ' ' || markdown[m] === '\t' || markdown[m] === '>')) m += 1;
      t += 1;
      continue;
    }
    if (mc === '\n' && tc === ' ') {
      m += 1;
      while (m < markdown.length && (markdown[m] === ' ' || markdown[m] === '\t' || markdown[m] === '>')) m += 1;
      t += 1;
      continue;
    }
    if (mc !== tc) return -1;
    m += 1;
    t += 1;
  }
  return m;
}

/**
 * Claim each text node against the markdown with a cursor that never rewinds.
 * Duplicates are unambiguous by construction: the Nth occurrence is claimed by the
 * Nth node, never by a search.
 */
function align(markdown, nodes) {
  const ranges = [];
  let cursor = 0;
  for (const node of nodes) {
    let at = -1;
    let end = -1;
    for (let probe = cursor; probe <= markdown.length - 1; probe += 1) {
      const finish = matchAt(markdown, node.text, probe);
      if (finish >= 0) { at = probe; end = finish; break; }
    }
    if (at < 0) return { ok: false, failed: node, cursor };
    ranges.push({ pos: node.pos, from: at, to: end, text: node.text });
    cursor = end;
  }
  return { ok: true, ranges };
}

export { align, matchAt, textNodes };

if (process.argv[2]) {
  const corpus = JSON.parse(readFileSync(process.argv[2], 'utf8')).map((r) => r.markdown ?? '');
  const EXTRA = {
    'escaped asterisk': 'literal \\*stars\\* here',
    'entity': 'AT&amp;T and &lt;tag&gt;',
    'hard break': 'line one  \nline two',
    'duplicate text': 'alpha then beta then alpha again',
    'astral': 'a 🧠 then **bold 🧠** then 🧠',
    'underscore emphasis': '_it_ and __bold__ text',
    'indented code': 'text\n\n    code here\n',
    'crlf': 'line one\r\nline two\r\n\r\npara two',
    'nbsp': 'a b non-breaking',
    'setext': 'Title\n=====\n\nbody',
  };
  
  let okRaw = 0; let okCanon = 0; const failures = [];
  const cases = [
    ...corpus.map((md, i) => [`real#${i}`, md]),
    ...Object.entries(EXTRA),
  ].filter(([, md]) => md.trim().length);
  
  for (const [label, md] of cases) {
    const doc = defaultMarkdownParser.parse(md);
    const nodes = textNodes(doc);
    const raw = align(md, nodes);
    const canonical = defaultMarkdownSerializer.serialize(doc);
    const canon = align(canonical, textNodes(defaultMarkdownParser.parse(canonical)));
    if (raw.ok) okRaw += 1; else failures.push([label, 'RAW', raw]);
    if (canon.ok) okCanon += 1; else failures.push([label, 'CANONICAL', canon]);
  }
  
  console.log(`alignment against RAW markdown:       ${okRaw}/${cases.length}`);
  console.log(`alignment against CANONICAL markdown: ${okCanon}/${cases.length}`);
  if (failures.length) {
    console.log('\nfailures (text node that could not be claimed in order):');
    for (const [label, which, r] of failures.slice(0, 12)) {
      console.log(`  ${which.padEnd(10)} ${label.padEnd(14)} cursor@${r.cursor} wanted ${JSON.stringify(r.failed.text.slice(0, 50))}`);
    }
  }
  console.log(`\nGATE 4 (annotations mappable without searching): ${failures.length === 0 ? 'PASS' : 'FAIL'}`);
}
