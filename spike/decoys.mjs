// Codex's four false-positive inputs. Its claim: the matcher takes the FIRST
// forward match, which can land inside SOURCE-ONLY regions — link destinations,
// fence info strings, image alt text, reference definitions — none of which are
// text nodes. Alignment then reports success with wrong ranges, which is worse
// than failing. Verifying rather than taking its word for it.
import { defaultMarkdownParser } from 'prosemirror-markdown';
import { align, textNodes } from './align.mjs';

const CASES = [
  ['link destination', '[a](x)x', 'the visible trailing x'],
  ['fence info string', '```js\njs\n```', 'the code content js'],
  ['image alt text', '![caption](asset)caption', 'the visible trailing caption'],
  ['reference definition', '[id]: /url "id"\n\n[id]', 'the shortcut link id'],
];

let wrong = 0;
for (const [name, md, expected] of CASES) {
  const nodes = textNodes(defaultMarkdownParser.parse(md));
  const result = align(md, nodes);
  console.log(`--- ${name}`);
  console.log('  source   :', JSON.stringify(md));
  console.log('  textnodes:', JSON.stringify(nodes.map((n) => n.text)));
  if (!result.ok) { console.log('  claimed  : ALIGNMENT FAILED (loud, therefore safe)'); continue; }
  for (const r of result.ranges) {
    // The claim is only correct if the claimed source slice is where that text
    // actually renders from. Print it so a wrong claim is visible.
    console.log(`  claimed  : [${r.from},${r.to}) = ${JSON.stringify(md.slice(r.from, r.to))} for node ${JSON.stringify(r.text)}`);
  }
  console.log('  expected :', expected);
  wrong += 1;
}
console.log(`\n${wrong} of ${CASES.length} decoys aligned "successfully" — inspect the ranges above for silent misclaims.`);
