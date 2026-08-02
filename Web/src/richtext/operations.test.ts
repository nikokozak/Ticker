// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TextSelection } from 'prosemirror-state';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';
import {
  aiWritingRange,
  applyAIMarkdown,
  focusAtEnd,
  insertImage,
  promoteConversationMarkdown,
  removePDFHighlightLink,
  selectedPDFHighlight,
  selectText,
  setImageWidth,
  streamAIMarkdown,
  updateConversationBlockMarkdown,
} from './operations';
import { provenanceSpans } from './provenance';

/**
 * ProseMirror measures the DOM to scroll a selection into view, and jsdom
 * implements no layout. Empty rectangles are enough: the tests assert document
 * state, and the measurement only has to not throw.
 */
beforeAll(() => {
  const empty = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const none = () => Object.assign([] as unknown[], { item: () => null });
  for (const proto of [Range.prototype, Element.prototype, Text.prototype] as Array<{ getClientRects?: unknown; getBoundingClientRect?: unknown }>) {
    proto.getClientRects ??= none;
    proto.getBoundingClientRect ??= empty;
  }
});

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

afterEach(() => {
  editor?.destroy();
  editor = null;
  document.body.innerHTML = '';
});

function find(ed: RichTextEditor, text: string): { from: number; to: number } {
  let at = -1;
  ed.view.state.doc.descendants((node, pos) => {
    if (at < 0 && node.isText && node.text?.includes(text)) at = pos + node.text.indexOf(text);
  });
  if (at < 0) throw new Error(`no ${JSON.stringify(text)}`);
  return { from: at, to: at + text.length };
}

function undo(ed: RichTextEditor): void {
  const event = new KeyboardEvent('keydown', { key: 'z', ctrlKey: true, bubbles: true, cancelable: true });
  ed.view.someProp('handleKeyDown', (handler) => handler(ed.view, event));
}

describe('applying what the AI wrote', () => {
  it('rewrites a sentence inline rather than making it its own block', () => {
    const ed = open('One sentence. Second sentence. Third.');
    applyAIMarkdown(ed.view, find(ed, 'Second sentence.'), 'A rewritten sentence.');
    expect(ed.getMarkdownProjection()).toBe('One sentence. A rewritten sentence. Third.');
    expect(ed.view.state.doc.childCount).toBe(1);
  });

  it('keeps the formatting the AI asked for', () => {
    const ed = open('Replace this.');
    applyAIMarkdown(ed.view, find(ed, 'Replace this.'), 'Now **bold** and [linked](https://x.test).');
    expect(ed.getMarkdownProjection()).toBe('Now **bold** and [linked](https://x.test).');
  });

  it('inserts whole blocks when the AI produced them', () => {
    const ed = open('Before.\n\nReplace me.\n\nAfter.');
    applyAIMarkdown(ed.view, find(ed, 'Replace me.'), '## A heading\n\nAnd a paragraph.');
    expect(ed.getMarkdownProjection()).toBe('Before.\n\n## A heading\n\nAnd a paragraph.\n\nAfter.');
  });

  it('is exactly ONE undo step', () => {
    // The property the old editor kept losing: an operation assembled from several
    // dispatches takes several undos to remove, which reads as a broken undo.
    const ed = open('One sentence. Second sentence. Third.');
    const before = ed.getMarkdownProjection();
    applyAIMarkdown(ed.view, find(ed, 'Second sentence.'), 'A **much** longer rewritten sentence, with formatting.');
    expect(ed.getMarkdownProjection()).not.toBe(before);
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe(before);
  });

  it('reports the range it wrote, and highlights it', () => {
    const ed = open('One. Two. Three.');
    const range = applyAIMarkdown(ed.view, find(ed, 'Two.'), 'A longer replacement.');
    expect(ed.view.state.doc.textBetween(range.from, range.to)).toBe('A longer replacement.');
    expect(aiWritingRange(ed.view.state)).toEqual(range);
  });

  it('the highlight follows the text when the user edits before it', () => {
    // The reported bug: "highlighting for the AI generated areas is broken in areas
    // where I have modified it". ProseMirror maps the range; the old code did not.
    const ed = open('One. Two. Three.');
    const range = applyAIMarkdown(ed.view, find(ed, 'Two.'), 'AI text.');
    ed.view.dispatch(ed.view.state.tr.insertText('XXXX', 1));
    const moved = aiWritingRange(ed.view.state);
    expect(moved).toEqual({ from: range.from + 4, to: range.to + 4 });
    expect(ed.view.state.doc.textBetween(moved!.from, moved!.to)).toBe('AI text.');
  });

  it('the highlight grows with text typed inside it', () => {
    const ed = open('One. Two. Three.');
    const range = applyAIMarkdown(ed.view, find(ed, 'Two.'), 'AI text.');
    ed.view.dispatch(ed.view.state.tr.insertText('!', range.from + 2));
    const grown = aiWritingRange(ed.view.state)!;
    expect(ed.view.state.doc.textBetween(grown.from, grown.to)).toBe('AI! text.');
  });

  it('clears when a new range replaces it', () => {
    const ed = open('One. Two. Three.');
    applyAIMarkdown(ed.view, find(ed, 'Two.'), 'First AI text.');
    const second = applyAIMarkdown(ed.view, find(ed, 'Three.'), 'Second AI text.');
    expect(aiWritingRange(ed.view.state)).toEqual(second);
  });

  it('never writes the highlight into the document', () => {
    const ed = open('One. Two. Three.');
    applyAIMarkdown(ed.view, find(ed, 'Two.'), 'AI text.');
    expect(ed.getMarkdownProjection()).toBe('One. AI text. Three.');
    expect(ed.getMarkdownProjection()).not.toMatch(/richtext-ai-written|<span/);
  });
});

describe('promoting a conversation answer', () => {
  it('isolates adjacent typing and undo removes both the promotion and its AI provenance', () => {
    const ed = open('Anchor block.\n\nAfter.');
    const before = ed.getDocumentJSON();
    const anchor = find(ed, 'Anchor block.');
    const inserted = promoteConversationMarkdown(
      ed.view,
      ed.view.state.doc.resolve(anchor.from).after(1),
      'First **paragraph**.\n\nSecond [citation](https://example.test).',
      {
        requestId: 'conversation-request',
        model: 'test-model',
        verb: 'thread',
        threadId: 'thread-1',
      },
    );

    expect(ed.getMarkdownProjection()).toBe(
      'Anchor block.\n\nFirst **paragraph**.\n\nSecond [citation](https://example.test).\n\nAfter.',
    );
    expect(provenanceSpans(ed.view.state)).toEqual([
      expect.objectContaining({
        from: inserted.from,
        to: inserted.to,
        origin: 'ai',
        requestId: 'conversation-request',
        meta: { model: 'test-model', verb: 'thread', threadId: 'thread-1' },
      }),
    ]);
    const promoted = ed.getDocumentJSON();
    const after = find(ed, 'After.');
    ed.view.dispatch(ed.view.state.tr.insertText(' typed', after.to));

    undo(ed);
    expect(ed.getDocumentJSON()).toBe(promoted);
    expect(provenanceSpans(ed.view.state)).toHaveLength(1);
    undo(ed);
    expect(ed.getDocumentJSON()).toBe(before);
    expect(provenanceSpans(ed.view.state)).toEqual([]);
  });
});

describe('updating a conversation anchor', () => {
  it('clamps huge, empty, and block-splitting replacements to the live anchor and undoes byte-exactly', () => {
    const cases = [
      'x'.repeat(20_000),
      '',
      '# Replacement\n\nFirst paragraph.\n\n- one\n- two\n\n> final block',
    ];
    for (const markdown of cases) {
      const ed = open('Outside before.\n\nTarget text.\n\nOutside after.');
      const beforeMarkdown = ed.getMarkdownProjection();
      const beforeJSON = ed.getDocumentJSON();
      const first = ed.view.state.doc.firstChild!.toJSON();
      const last = ed.view.state.doc.lastChild!.toJSON();
      const replaced = updateConversationBlockMarkdown(ed.view, find(ed, 'Target text.'), markdown, {
        requestId: `update-${markdown.length}`,
        model: 'test-model',
        verb: 'thread',
        threadId: 'thread-1',
      });

      expect(ed.view.state.doc.firstChild!.toJSON()).toEqual(first);
      expect(ed.view.state.doc.lastChild!.toJSON()).toEqual(last);
      if (markdown) {
        expect(aiWritingRange(ed.view.state)).toEqual(replaced);
        expect(provenanceSpans(ed.view.state)).toEqual([
          expect.objectContaining({
            from: replaced.from,
            to: replaced.to,
            origin: 'ai',
            requestId: `update-${markdown.length}`,
          }),
        ]);
      } else expect(provenanceSpans(ed.view.state)).toEqual([]);
      undo(ed);
      expect(ed.getMarkdownProjection()).toBe(beforeMarkdown);
      expect(ed.getDocumentJSON()).toBe(beforeJSON);
      expect(provenanceSpans(ed.view.state)).toEqual([]);
      ed.destroy();
      editor = null;
    }
  });
});

describe('images', () => {
  it('inserts one at the cursor with no width token in the text', () => {
    const ed = open('before');
    focusAtEnd(ed.view);
    insertImage(ed.view, { src: 'ticker-asset://s/a.png', alt: 'shot' });
    expect(ed.getMarkdownProjection()).toBe('before![shot](ticker-asset://s/a.png)');
    expect(ed.view.state.doc.textContent).toBe('before');
  });

  it('resizes one already in the document, in a single step', () => {
    const ed = open('![shot](ticker-asset://s/a.png)');
    const pos = ed.view.state.doc.content.size - 2;
    setImageWidth(ed.view, pos, 300);
    expect(ed.getMarkdownProjection()).toBe('![shot](ticker-asset://s/a.png){width=300}');
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe('![shot](ticker-asset://s/a.png)');
  });

  it('refuses a width on an image that is not a ticker asset', () => {
    const ed = open('x');
    expect(() => insertImage(ed.view, { src: 'https://example.test/a.png', width: 300 })).toThrow();
  });

  it('ignores a width outside the range the UI can produce', () => {
    const ed = open('![shot](ticker-asset://s/a.png)');
    const pos = ed.view.state.doc.content.size - 2;
    setImageWidth(ed.view, pos, 5000);
    expect(ed.getMarkdownProjection()).toBe('![shot](ticker-asset://s/a.png)');
  });
});

describe('finding text', () => {
  it('selects a hit and puts the cursor on it', () => {
    const ed = open('first paragraph\n\nsecond paragraph with a needle in it');
    expect(selectText(ed.view, 'needle')).toBe(true);
    const { from, to } = ed.view.state.selection;
    expect(ed.view.state.doc.textBetween(from, to)).toBe('needle');
  });

  it('searches the document, not the markdown', () => {
    // "bold" must be findable inside **bold**, and a search for '**' must fail,
    // because the markers are not in the document at all.
    const ed = open('a **bold** word');
    expect(selectText(ed.view, 'bold')).toBe(true);
    expect(selectText(ed.view, '**')).toBe(false);
  });

  it('finds a phrase that spans a mark boundary', () => {
    // A mark boundary SPLITS the text into separate nodes, so searching node by
    // node cannot find "quick brown" in `*quick* brown` — even though that is
    // exactly what the reader sees.
    const ed = open('the *quick* brown fox');
    expect(selectText(ed.view, 'quick')).toBe(true);
    expect(selectText(ed.view, 'quick brown')).toBe(true);
    expect(selectText(ed.view, 'the quick brown fox')).toBe(true);
  });

  it('finds a phrase that spans a line break', () => {
    const ed = open('one\ntwo');
    expect(selectText(ed.view, 'one two')).toBe(true);
  });

  it('finds a phrase that spans a link', () => {
    const ed = open('see [the paper](https://x.test) now');
    expect(selectText(ed.view, 'see the paper now')).toBe(true);
  });

  it('selects exactly the matched text', () => {
    const ed = open('the *quick* brown fox');
    selectText(ed.view, 'quick brown');
    const { from, to } = ed.view.state.selection;
    expect(ed.view.state.doc.textBetween(from, to)).toBe('quick brown');
  });

  it('reports a miss instead of moving the cursor', () => {
    const ed = open('some text');
    ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, 3)));
    expect(selectText(ed.view, 'absent')).toBe(false);
    expect(ed.view.state.selection.from).toBe(3);
  });
});

describe('PDF highlight links', () => {
  const sourceId = '11111111-1111-1111-1111-111111111111';
  const highlightId = '22222222-2222-2222-2222-222222222222';
  const href = `ticker-pdf://${sourceId}?highlight=${highlightId}&page=4`;

  it('finds the selected highlight and removes only its links without deleting text', () => {
    const ed = open(`Before [linked **words**](${href}) after. Another [copy](${href}).`);
    const range = find(ed, 'linked');
    ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, range.from, range.to)));

    expect(selectedPDFHighlight(ed.view.state)).toEqual({ sourceId, highlightId });
    expect(removePDFHighlightLink(ed.view, highlightId)).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('Before linked **words** after. Another copy.');

    undo(ed);
    expect(ed.getMarkdownProjection()).toBe('Before linked **words** after. Another copy.');
  });

  it('does not offer removal for page citations without persisted highlights', () => {
    const ed = open(`Read [the source](ticker-pdf://${sourceId}?page=4).`);
    const range = find(ed, 'the source');
    ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, range.from, range.to)));

    expect(selectedPDFHighlight(ed.view.state)).toBeNull();
  });
});

describe('focusing at the end', () => {
  it('puts the cursor after the last character', () => {
    const ed = open('one\n\ntwo');
    focusAtEnd(ed.view);
    expect(ed.view.state.selection.empty).toBe(true);
    // Inside the last paragraph, not after it.
    expect(ed.view.state.selection.from).toBe(ed.view.state.doc.content.size - 1);
  });
});

describe('a streaming AI reply', () => {
  // Chunks cannot be parsed independently: a stream splits wherever it likes, so
  // `**bo` and `ld**` each parse to plain text and neither is bold.
  it('is correct even when a chunk splits a marker', () => {
    const ed = open('Replace this.');
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    for (const chunk of ['Now **bo', 'ld** and ', '[lin', 'ked](https://x.', 'test).']) stream.push(chunk);
    expect(ed.getMarkdownProjection()).toBe('Now **bold** and [linked](https://x.test).');
  });

  it('is correct when a chunk splits a list marker', () => {
    const ed = open('Replace this.');
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    for (const chunk of ['* one\n', '* t', 'wo']) stream.push(chunk);
    expect(ed.getMarkdownProjection()).toBe('* one\n* two');
  });

  it('is still ONE undo step however many frames it took', () => {
    const ed = open('One. Replace this. Three.');
    const before = ed.getMarkdownProjection();
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    for (const chunk of ['A ', '**streamed** ', 'reply.']) stream.push(chunk);
    expect(ed.getMarkdownProjection()).toBe('One. A **streamed** reply. Three.');
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe(before);
  });

  it('keeps that undo when a later frame changes the block structure', () => {
    const ed = open('Replace this.');
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    stream.push('A reply.');
    stream.push('\n\n* with a source');
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe('Replace this.');
  });

  it('does not include the preceding user edit in its undo', () => {
    const ed = open('Replace this.');
    ed.view.dispatch(ed.view.state.tr.insertText('User ', 1));
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    stream.push('AI reply.');
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe('User Replace this.');
  });

  it('reports the range it wrote, and highlights it', () => {
    const ed = open('One. Replace this. Three.');
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    stream.push('A reply.');
    const range = stream.done();
    expect(ed.view.state.doc.textBetween(range.from, range.to)).toBe('A reply.');
    expect(aiWritingRange(ed.view.state)).toEqual(range);
  });
});

describe('finding text near a block boundary', () => {
  // The position after the last character of a paragraph and the position before
  // the first character of the next one are different numbers, and a selection
  // between them crosses a boundary ProseMirror rejects.
  const cases: Array<[string, string]> = [
    ['match ending at a paragraph end', 'foo\n\nbar'],
    ['match at the very end of the document', 'foo\n\nbar'],
    ['match ending at a heading end', '## foo\n\nbar'],
    ['match ending at a list item end', '* foo\n* bar'],
  ];
  for (const [name, markdown] of cases) {
    it(name, () => {
      const ed = open(markdown);
      expect(selectText(ed.view, 'foo')).toBe(true);
      const { from, to } = ed.view.state.selection;
      expect(ed.view.state.doc.textBetween(from, to)).toBe('foo');
      // The endpoints must sit in the same textblock, or the selection is invalid.
      expect(ed.view.state.doc.resolve(from).parent).toBe(ed.view.state.doc.resolve(to).parent);
    });
  }

  it('finds the last word of the document', () => {
    const ed = open('foo\n\nbar');
    expect(selectText(ed.view, 'bar')).toBe(true);
    const { from, to } = ed.view.state.selection;
    expect(ed.view.state.doc.textBetween(from, to)).toBe('bar');
  });
});

describe('typing while the AI is streaming', () => {
  it('does not let the AI undo swallow what the user typed mid-stream', () => {
    const ed = open('Replace this.');
    const stream = streamAIMarkdown(ed.view, find(ed, 'Replace this.'));
    stream.push('AI ');

    expect(ed.view.editable).toBe(false);
    // A browser only turns typing into a transaction for an editable view.
    if (ed.view.editable) ed.view.dispatch(ed.view.state.tr.insertText('MINE ', 1));
    expect(ed.view.state.doc.textContent).toBe('AI');

    stream.push('reply.');
    stream.done();
    expect(ed.view.editable).toBe(true);
    expect(ed.getMarkdownProjection()).toBe('AI reply.');
    undo(ed);
    expect(ed.getMarkdownProjection()).toBe('Replace this.');
  });
});
