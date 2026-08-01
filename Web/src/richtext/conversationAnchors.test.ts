// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';
import {
  conversationAnchorText,
  conversationAnchorTextForStorage,
  conversationAnchors,
  conversationDecorationTargets,
  conversationMarkerBlockPositions,
  conversationRenderPosition,
  fullBlockConversationAnchor,
  hasConversationAnchorTextDrifted,
  setConversationAnchors,
  setConversationVisibleRanges,
} from './conversationAnchors';

let editor: RichTextEditor | null = null;

function open(markdown: string): RichTextEditor {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  editor = createRichTextEditor({
    parent,
    docJSON: JSON.stringify(parseMarkdown(markdown).toJSON()),
  });
  return editor;
}

function find(ed: RichTextEditor, text: string): { from: number; to: number } {
  let from = -1;
  ed.view.state.doc.descendants((node, pos) => {
    if (from < 0 && node.isText && node.text?.includes(text)) from = pos + node.text.indexOf(text);
  });
  if (from < 0) throw new Error(`no ${JSON.stringify(text)}`);
  return { from, to: from + text.length };
}

function recordFullBlock(ed: RichTextEditor, text: string) {
  const anchor = fullBlockConversationAnchor(ed.view.state.doc, find(ed, text).from, 'thread-1');
  if (!anchor) throw new Error('expected a non-empty block anchor');
  ed.view.dispatch(setConversationAnchors(ed.view.state.tr, [anchor]));
  return anchor;
}

afterEach(() => {
  editor?.destroy();
  editor = null;
  document.body.innerHTML = '';
});

describe('conversation anchor lifecycle', () => {
  it('rule 1: starts as the full UTF-16 block and renders after its last intersecting block', () => {
    const ed = open('A🙂B');
    const anchor = recordFullBlock(ed, '🙂');

    expect(anchor.from).toBe(1);
    expect(anchor.to - anchor.from).toBe(4);
    expect(conversationAnchorText(ed.view.state.doc, anchor)).toBe('A🙂B');
    expect(conversationRenderPosition(ed.view.state.doc, anchor)).toBe(ed.view.state.doc.content.size);
  });

  it('rule 2: a split spans both halves and renders after the second', () => {
    const ed = open('Alpha beta');
    recordFullBlock(ed, 'Alpha');
    ed.view.dispatch(ed.view.state.tr.split(find(ed, 'beta').from));

    const [anchor] = conversationAnchors(ed.view.state);
    expect(conversationAnchorText(ed.view.state.doc, anchor)).toBe('Alpha \nbeta');
    expect(conversationRenderPosition(ed.view.state.doc, anchor)).toBe(ed.view.state.doc.content.size);
    expect(anchor.detached).toBe(false);
  });

  it('rule 3: a merge keeps the range in the merged block', () => {
    const ed = open('Alpha beta');
    recordFullBlock(ed, 'Alpha');
    ed.view.dispatch(ed.view.state.tr.split(find(ed, 'beta').from));
    const secondBlock = ed.view.state.doc.resolve(find(ed, 'beta').from).before(1);
    ed.view.dispatch(ed.view.state.tr.join(secondBlock));

    const [anchor] = conversationAnchors(ed.view.state);
    expect(conversationAnchorText(ed.view.state.doc, anchor)).toBe('Alpha beta');
    expect(conversationRenderPosition(ed.view.state.doc, anchor)).toBe(ed.view.state.doc.content.size);
    expect(anchor.detached).toBe(false);
  });

  it('rule 4: deleting the range to empty detaches it without deleting it', () => {
    const ed = open('Delete me');
    const original = recordFullBlock(ed, 'Delete');
    ed.view.dispatch(ed.view.state.tr.delete(original.from, original.to));

    expect(conversationAnchors(ed.view.state)).toEqual([{
      threadId: 'thread-1',
      from: 1,
      to: 1,
      detached: true,
    }]);
    expect(conversationRenderPosition(ed.view.state.doc, conversationAnchors(ed.view.state)[0])).toBe(null);
  });

  it('rule 5: stores at most 200 characters and detects changed anchor text', () => {
    const ed = open(`${'a'.repeat(205)} end`);
    const anchor = recordFullBlock(ed, 'end');
    const stored = conversationAnchorTextForStorage(ed.view.state.doc, anchor);
    expect([...stored]).toHaveLength(200);
    expect(hasConversationAnchorTextDrifted(ed.view.state.doc, anchor, stored)).toBe(false);

    ed.view.dispatch(ed.view.state.tr.insertText('changed', anchor.from + 100, anchor.from + 105));
    expect(hasConversationAnchorTextDrifted(
      ed.view.state.doc,
      conversationAnchors(ed.view.state)[0],
      stored,
    )).toBe(true);
  });
});

it('bounds decoration traversal to the supplied visible ranges and collapses overlaps', () => {
  const ed = open('First\n\nMiddle\n\nLast');
  const first = fullBlockConversationAnchor(ed.view.state.doc, find(ed, 'First').from, 'first')!;
  const last = fullBlockConversationAnchor(ed.view.state.doc, find(ed, 'Last').from, 'last')!;
  const duplicate = { ...last, threadId: 'also-last' };

  const firstTargets = conversationDecorationTargets(
    ed.view.state.doc,
    conversationMarkerBlockPositions(ed.view.state.doc, [first, last, duplicate]),
    [{ from: first.from, to: first.to }],
    null,
  );
  expect(firstTargets).toHaveLength(1);
  expect(firstTargets[0]).toMatchObject({ right: true, contentFrom: first.from, contentTo: first.to });

  const lastTargets = conversationDecorationTargets(
    ed.view.state.doc,
    conversationMarkerBlockPositions(ed.view.state.doc, [first, last, duplicate]),
    [{ from: last.from, to: last.to }],
    null,
  );
  expect(lastTargets).toHaveLength(1);
  expect(lastTargets[0].right).toBe(true);
});

it('renders one passive right glyph class and the current-block left line class', () => {
  const ed = open('Visible block');
  const anchor = fullBlockConversationAnchor(ed.view.state.doc, 1, 'one')!;
  ed.view.dispatch(setConversationAnchors(ed.view.state.tr, [anchor, { ...anchor, threadId: 'two' }]));
  ed.view.dispatch(setConversationVisibleRanges(ed.view.state.tr, [{ from: anchor.from, to: anchor.to }]));

  const block = ed.view.dom.querySelector('p');
  expect(block?.classList.contains('conversation-block-active')).toBe(true);
  expect(block?.classList.contains('conversation-block-anchored')).toBe(true);
});
