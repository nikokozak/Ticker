// Codex's P0: canonicalisation defines OUTPUT form, but Swift keeps appending RAW
// markdown. appendToStreamDocument concatenates a fragment with "\n\n" and shifts
// spans by raw UTF-16 length — it never parses. So the steady-state invariant
// "every stored document is serializer output" only survives if:
//
//   canonical(doc) + "\n\n" + canonical(fragment) === canonical(doc + "\n\n" + fragment)
//
// If that closure holds, an append can be canonicalised independently and the
// document stays canonical, so offsets stay well defined. If it does not, every
// append silently de-canonicalises the document and the whole plan needs a
// different ingress story. Assumed; now measured.
import { readFileSync } from 'node:fs';
import { defaultMarkdownParser, defaultMarkdownSerializer } from 'prosemirror-markdown';

const canon = (md) => defaultMarkdownSerializer.serialize(defaultMarkdownParser.parse(md));

// Real ingress shapes, taken from what the Swift side actually writes.
const FRAGMENTS = {
  'quick capture (quote + italic attribution)': '> captured text here\n\n*from Safari*',
  'AI answer (heading + list)': '## Summary\n\n- first point\n- second point',
  'plain sentence': 'Just a plain captured sentence.',
  'image': '![shot](ticker-asset://s/a.png){width=300}',
  'citation + prose': 'See [Book p.3](ticker-pdf://abc?page=3&q=a%20quote) for detail.',
  'bare list': '- one\n- two',
  'trailing-newline fragment': 'text with trailing newline\n',
};

const corpus = JSON.parse(readFileSync(process.argv[2], 'utf8'))
  .map((r) => r.markdown ?? '')
  .filter((md) => md.trim().length);

let checked = 0;
const failures = [];

for (const [name, fragment] of Object.entries(FRAGMENTS)) {
  for (const [i, doc] of corpus.entries()) {
    const composed = `${canon(doc)}\n\n${canon(fragment)}`;
    const recanon = canon(composed);
    checked += 1;
    if (composed !== recanon) {
      failures.push({ name, doc: i, composed, recanon });
    }
  }
}

console.log(`append closure: ${checked - failures.length}/${checked} hold`);
if (failures.length) {
  const byFragment = new Map();
  for (const f of failures) byFragment.set(f.name, (byFragment.get(f.name) ?? 0) + 1);
  console.log('\nfailing fragment shapes:');
  for (const [name, n] of byFragment) console.log(`  ${String(n).padStart(3)} docs | ${name}`);
  const f = failures[0];
  for (let i = 0; i < Math.min(f.composed.length, f.recanon.length); i += 1) {
    if (f.composed[i] !== f.recanon[i]) {
      console.log(`\nfirst divergence (${f.name}, doc#${f.doc}) at offset ${i}:`);
      console.log('  appended :', JSON.stringify(f.composed.slice(Math.max(0, i - 30), i + 30)));
      console.log('  recanon  :', JSON.stringify(f.recanon.slice(Math.max(0, i - 30), i + 30)));
      break;
    }
  }
}
console.log(`\nGATE 3 (append keeps documents canonical): ${failures.length === 0 ? 'PASS' : 'FAIL'}`);
