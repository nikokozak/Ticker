// @vitest-environment jsdom
import { undo } from 'prosemirror-history';
import { TextSelection } from 'prosemirror-state';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';
import {
  conversationAnchorText,
  conversationAnchorTextForStorage,
  conversationAnchors,
  conversationDecorationTargets,
  conversationMarkerBlockPositions,
  conversationRenderPosition,
  conversationSurfacePosition,
  fullBlockConversationAnchor,
  hasConversationAnchorTextDrifted,
  refreshConversationViewport,
  setConversationAnchors,
  setConversationSurface,
  setConversationVisibleRanges,
  type ConversationAnchorFieldOptions,
} from './conversationAnchors';

let editor: RichTextEditor | null = null;

function open(
  markdown: string,
  onUpdate?: () => void,
  conversations?: ConversationAnchorFieldOptions,
): RichTextEditor {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  editor = createRichTextEditor({
    parent,
    docJSON: JSON.stringify(parseMarkdown(markdown).toJSON()),
    onUpdate,
    conversations,
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

function press(ed: RichTextEditor, key: string): boolean {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
  return Boolean(ed.view.someProp('handleKeyDown', (handler) => handler(ed.view, event)));
}

afterEach(() => {
  editor?.destroy();
  editor = null;
  document.body.innerHTML = '';
});

describe('conversation anchor lifecycle', () => {
  it('rule 1: starts as the full block in ProseMirror positions and renders after it', () => {
    const ed = open('A🙂B');
    const anchor = recordFullBlock(ed, '🙂');

    expect(anchor.from).toBe(1);
    expect(anchor.to - anchor.from).toBe(4);
    expect(conversationAnchorText(ed.view.state.doc, anchor)).toBe('A🙂B');
    expect(conversationRenderPosition(ed.view.state.doc, anchor)).toBe(ed.view.state.doc.content.size);
  });

  it('renders a quote conversation after the blockquote container', () => {
    const ed = open('> Quoted passage.\n\nAfter.');
    const anchor = recordFullBlock(ed, 'Quoted passage.');
    expect(conversationRenderPosition(ed.view.state.doc, anchor))
      .toBeLessThan(conversationSurfacePosition(ed.view.state.doc, anchor)!);
    expect(conversationSurfacePosition(ed.view.state.doc, anchor))
      .toBe(ed.view.state.doc.child(0).nodeSize);
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

  it('does not grow across a split at the trailing edge or move its glyph', () => {
    const ed = open('ABC');
    const original = recordFullBlock(ed, 'ABC');
    ed.view.dispatch(ed.view.state.tr.split(original.to));

    const [anchor] = conversationAnchors(ed.view.state);
    expect(anchor).toEqual(original);
    expect(conversationRenderPosition(ed.view.state.doc, anchor)).toBe(ed.view.state.doc.child(0).nodeSize);
    expect(conversationMarkerBlockPositions(ed.view.state.doc, [anchor])).toEqual(new Set([0]));
  });

  it('extends across plain text inserted at the trailing edge', () => {
    const ed = open('ABC');
    const original = recordFullBlock(ed, 'ABC');
    ed.view.dispatch(ed.view.state.tr.insertText('D', original.to));

    const [anchor] = conversationAnchors(ed.view.state);
    expect(anchor.to).toBe(original.to + 1);
    expect(conversationAnchorText(ed.view.state.doc, anchor)).toBe('ABCD');
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

  it('reattaches a detached anchor when undo restores its range', () => {
    const ed = open('Delete me');
    const original = recordFullBlock(ed, 'Delete');
    ed.view.dispatch(ed.view.state.tr.delete(original.from, original.to));
    expect(conversationAnchors(ed.view.state)[0].detached).toBe(true);

    expect(undo(ed.view.state, (tr) => ed.view.dispatch(tr))).toBe(true);
    expect(conversationAnchors(ed.view.state)).toEqual([original]);
  });

  it('rule 5: stores at most 200 UTF-16 code units and detects changed anchor text', () => {
    const ed = open(`${'🙂'.repeat(101)}tail`);
    const anchor = recordFullBlock(ed, 'tail');
    const stored = conversationAnchorTextForStorage(ed.view.state.doc, anchor);
    expect(stored).toHaveLength(200);
    expect([...stored]).toHaveLength(100);
    expect(hasConversationAnchorTextDrifted(ed.view.state.doc, anchor, stored)).toBe(false);

    ed.view.dispatch(ed.view.state.tr.insertText('changed', anchor.from + 100, anchor.from + 102));
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

it('routes gutter clicks and mounts only one caret-excluded block widget', () => {
  const onCreate = vi.fn();
  const onOpen = vi.fn();
  const ed = open('Visible block', undefined, { onCreate, onOpen });
  const anchor = fullBlockConversationAnchor(ed.view.state.doc, 1, 'one')!;
  ed.view.dispatch(setConversationAnchors(ed.view.state.tr, [anchor]));
  ed.view.dispatch(setConversationVisibleRanges(ed.view.state.tr, [{ from: anchor.from, to: anchor.to }]));
  const block = ed.view.dom.querySelector('p')!;
  vi.spyOn(block, 'getBoundingClientRect').mockReturnValue({
    left: 10, right: 110, top: 0, bottom: 28, width: 100, height: 28, x: 10, y: 0,
    toJSON: () => ({}),
  });

  block.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 0 }));
  expect(onCreate).toHaveBeenCalledWith({ ...anchor, threadId: '' });
  block.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 120 }));
  expect(onOpen).toHaveBeenCalledWith('one');

  const before = ed.getDocumentJSON();
  ed.view.dispatch(setConversationSurface(ed.view.state.tr, { key: 'first', anchor }));
  ed.view.dispatch(setConversationSurface(ed.view.state.tr, { key: 'second', anchor }));
  const widgets = ed.view.dom.querySelectorAll<HTMLElement>('[data-conversation-widget]');
  expect(widgets).toHaveLength(1);
  expect(widgets[0].dataset.conversationWidget).toBe('second');
  expect(widgets[0].contentEditable).toBe('false');
  expect(ed.getDocumentJSON()).toBe(before);
});

it('moves an ArrowDown caret from the anchored block to the block below the widget', () => {
  const ed = open('Above\n\nBelow');
  const anchor = recordFullBlock(ed, 'Above');
  ed.view.dispatch(setConversationSurface(ed.view.state.tr, { key: 'open', anchor }));
  ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, anchor.to)));
  vi.spyOn(ed.view, 'endOfTextblock').mockReturnValue(true);

  expect(press(ed, 'ArrowDown')).toBe(true);
  expect(ed.view.state.selection.$head.parent.textContent).toBe('Below');
  expect(ed.view.dom.querySelector('.conversation-widget-host')?.contains(
    ed.view.domAtPos(ed.view.state.selection.head).node,
  )).toBe(false);
});

it('coalesces viewport and hover work per animation frame and skips unchanged targets', () => {
  const callbacks: FrameRequestCallback[] = [];
  let nextFrame = 0;
  const requestAnimationFrame = window.requestAnimationFrame;
  window.requestAnimationFrame = vi.fn((callback: FrameRequestCallback) => {
    callbacks.push(callback);
    nextFrame += 1;
    return nextFrame;
  });

  try {
    const onUpdate = vi.fn();
    const ed = open('Visible block', onUpdate);
    const dispatch = vi.spyOn(ed.view, 'dispatch');
    refreshConversationViewport(ed.view);
    refreshConversationViewport(ed.view);
    expect(callbacks).toHaveLength(1);
    callbacks.shift()!(0);
    expect(dispatch).toHaveBeenCalledTimes(1);

    refreshConversationViewport(ed.view);
    refreshConversationViewport(ed.view);
    callbacks.shift()!(0);
    expect(dispatch).toHaveBeenCalledTimes(1);

    vi.spyOn(ed.view, 'posAtCoords').mockReturnValue({ pos: 1, inside: 0 });
    ed.view.dom.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 1, clientY: 1 }));
    ed.view.dom.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 2, clientY: 2 }));
    expect(callbacks).toHaveLength(1);
    callbacks.shift()!(0);
    expect(dispatch).toHaveBeenCalledTimes(2);
    expect(onUpdate).not.toHaveBeenCalled();

    ed.view.dom.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 3, clientY: 3 }));
    callbacks.shift()!(0);
    expect(dispatch).toHaveBeenCalledTimes(2);
  } finally {
    window.requestAnimationFrame = requestAnimationFrame;
  }
});
