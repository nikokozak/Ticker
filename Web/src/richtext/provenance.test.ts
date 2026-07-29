// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { TextSelection } from 'prosemirror-state';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { toggleBlockquote } from './commands';
import {
  addProvenanceSpans,
  dissolveProvenanceSpans,
  hashProvenanceText,
  provenanceSpanAt,
  provenanceSpans,
  provenanceText,
  setProvenanceSpans,
  type ProvenanceSpan,
} from './provenance';

let editor: RichTextEditor | null = null;

function open(markdown: string): RichTextEditor {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  editor = createRichTextEditor({ parent, markdown });
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

function span(ed: RichTextEditor, text: string, overrides: Partial<ProvenanceSpan> = {}): ProvenanceSpan {
  const { from, to } = find(ed, text);
  return {
    spanId: overrides.spanId ?? `span-${text}`,
    from,
    to,
    origin: 'ai',
    meta: {},
    textHash: hashProvenanceText(ed.view.state.doc, { from, to }),
    createdAt: 0,
    ...overrides,
  };
}

function record(ed: RichTextEditor, ...spans: ProvenanceSpan[]): void {
  ed.view.dispatch(addProvenanceSpans(ed.view.state.tr, spans));
}

describe('spans follow the document', () => {
  it('records a span and finds it by position', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    expect(provenanceSpans(ed.view.state)).toHaveLength(1);
    expect(provenanceSpanAt(ed.view.state, written.from + 2)?.spanId).toBe(written.spanId);
    expect(provenanceSpanAt(ed.view.state, 1)).toBe(null);
  });

  it('moves with text inserted before it', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'The AI wrote this.'));
    ed.view.dispatch(ed.view.state.tr.insertText('XXXX', 1));
    const [moved] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, moved)).toBe('The AI wrote this.');
  });

  it('survives an edit far away in the document', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'The AI wrote this.'));
    ed.view.dispatch(ed.view.state.tr.insertText(' Added.', ed.view.state.doc.content.size - 1));
    expect(provenanceSpans(ed.view.state)).toHaveLength(1);
  });

  it('dissolves when its OWN text is edited', () => {
    // "The AI wrote this" stops being true the moment the user rewrites it. A span
    // that survived editing is exactly the stale highlight reported as broken.
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    ed.view.dispatch(ed.view.state.tr.insertText('!', written.from + 4));
    expect(provenanceSpans(ed.view.state)).toHaveLength(0);
  });

  it('dissolves when its text is deleted', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    ed.view.dispatch(ed.view.state.tr.delete(written.from + 2, written.from + 8));
    expect(provenanceSpans(ed.view.state)).toHaveLength(0);
  });

  it('survives typing against its edges, which is writing beside it', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    ed.view.dispatch(ed.view.state.tr.insertText('X', written.from));
    expect(provenanceSpans(ed.view.state)).toHaveLength(1);
    const [after] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, after)).toBe('The AI wrote this.');
  });

  it('forgets spans by id', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'One.'), span(ed, 'Three.'));
    ed.view.dispatch(dissolveProvenanceSpans(ed.view.state.tr, ['span-One.']));
    expect(provenanceSpans(ed.view.state).map((s) => s.spanId)).toEqual(['span-Three.']);
  });
});

describe('positions are stable across a save and reload', () => {
  // The reason positions can be stored at all: parsing is deterministic, so the
  // same markdown always yields the same positions. This is what replaces the
  // CodeMirror version's offsets into the markdown, which mean nothing once the
  // markdown is a derived artefact rather than the live document.
  it('a restored span covers the same text', () => {
    const source = '# Title\n\nOne. **The AI** wrote this. Three.\n\n* a\n* b';
    const ed = open(source);
    const written = span(ed, 'wrote this');
    record(ed, written);
    const text = provenanceText(ed.view.state.doc, written);

    const saved = ed.getMarkdown();
    expect(saved).toBe(source);
    ed.setMarkdown(saved);
    ed.view.dispatch(setProvenanceSpans(ed.view.state.tr, [written]));

    const [restored] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, restored)).toBe(text);
    expect(hashProvenanceText(ed.view.state.doc, restored)).toBe(written.textHash);
  });

  it('the hash detects a span restored onto text that has changed', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    ed.setMarkdown('One. Something else entirely. Three.');
    ed.view.dispatch(setProvenanceSpans(ed.view.state.tr, [written]));
    const [restored] = provenanceSpans(ed.view.state);
    expect(hashProvenanceText(ed.view.state.doc, restored)).not.toBe(written.textHash);
  });

  it('refuses a span that does not fit the document', () => {
    const ed = open('short');
    ed.view.dispatch(setProvenanceSpans(ed.view.state.tr, [
      { ...span(ed, 'short'), from: 0, to: 9999 },
    ]));
    expect(provenanceSpans(ed.view.state)).toHaveLength(0);
  });

  it('refuses a span too short to mean anything', () => {
    const ed = open('One. Two. Three.');
    ed.view.dispatch(setProvenanceSpans(ed.view.state.tr, [{ ...span(ed, 'One.'), from: 1, to: 2 }]));
    expect(provenanceSpans(ed.view.state)).toHaveLength(0);
  });
});

describe('positions survive the document settling into its stored form', () => {
  // The subtle one. Normalising a COPY at save time made the live document and the
  // persisted document two different trees, so a span recorded against the live one
  // pointed into a document that was never saved. Dropping a single empty paragraph
  // shifts everything after it by two. Normalising through a real transaction means
  // ProseMirror maps every plugin's positions, so they stay true.
  it('a span after an empty paragraph still covers its own text', () => {
    const ed = open('One.');
    // Reach the shape by typing, the way a user does: Enter twice, then more text.
    const end = ed.view.state.doc.content.size - 1;
    ed.view.dispatch(ed.view.state.tr.insert(end, [
      ed.view.state.schema.nodes.paragraph.create(),
      ed.view.state.schema.nodes.paragraph.create(null, ed.view.state.schema.text('The AI wrote this.')),
    ]));
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    expect(provenanceText(ed.view.state.doc, written)).toBe('The AI wrote this.');

    const saved = ed.getMarkdown(); // settles the document
    expect(saved).toBe('One.\n\nThe AI wrote this.'); // the empty paragraph is gone

    const [after] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, after)).toBe('The AI wrote this.');
    expect(hashProvenanceText(ed.view.state.doc, after)).toBe(written.textHash);

    // And it is still right after a reload, which is the point of storing positions.
    ed.setMarkdown(saved);
    ed.view.dispatch(setProvenanceSpans(ed.view.state.tr, [after]));
    const [restored] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, restored)).toBe('The AI wrote this.');
  });

  it('leaves an untouched paragraph BETWEEN two changed ones alone', () => {
    // The case that breaks a naive diff: dropping the empty paragraphs from
    // A / empty / AI / empty / Z leaves one differing run that CONTAINS the
    // unchanged AI paragraph, so replacing that run wholesale dissolves its spans.
    const ed = open('A');
    const { schema } = ed.view.state;
    const para = (text?: string) => schema.nodes.paragraph.create(null, text ? schema.text(text) : undefined);
    ed.view.dispatch(ed.view.state.tr.insert(ed.view.state.doc.content.size - 1, [
      para(), para('The AI wrote this.'), para(), para('Z'),
    ]));

    const written = span(ed, 'The AI wrote this.');
    record(ed, written);
    const selectionAt = written.from + 3;
    ed.view.dispatch(ed.view.state.tr.setSelection(TextSelection.create(ed.view.state.doc, selectionAt)));

    expect(ed.getMarkdown()).toBe('A\n\nThe AI wrote this.\n\nZ');

    const [survived] = provenanceSpans(ed.view.state);
    expect(survived, 'the span in the untouched paragraph was dissolved').toBeDefined();
    expect(provenanceText(ed.view.state.doc, survived)).toBe('The AI wrote this.');
    // And the cursor is still inside the same word, not collapsed to a boundary.
    expect(ed.view.state.doc.textBetween(ed.view.state.selection.from - 3, ed.view.state.selection.from)).toBe('The');
  });

  it('leaves positions after a trimmed text node alone', () => {
    const ed = open('One.');
    const { schema } = ed.view.state;
    ed.view.dispatch(ed.view.state.tr.insert(ed.view.state.doc.content.size - 1, [
      schema.nodes.paragraph.create(null, schema.text('trailing space here   ')),
      schema.nodes.paragraph.create(null, schema.text('The AI wrote this.')),
    ]));
    record(ed, span(ed, 'The AI wrote this.'));
    ed.getMarkdown();
    const [survived] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, survived)).toBe('The AI wrote this.');
  });

  it('settling is not something the user has to undo', () => {
    const ed = open('One.');
    const end = ed.view.state.doc.content.size - 1;
    ed.view.dispatch(ed.view.state.tr.insert(end, ed.view.state.schema.nodes.paragraph.create()));
    ed.getMarkdown();
    const settled = ed.getMarkdown();
    const event = new KeyboardEvent('keydown', { key: 'z', ctrlKey: true, bubbles: true, cancelable: true });
    ed.view.someProp('handleKeyDown', (handler) => handler(ed.view, event));
    expect(ed.getMarkdown()).toBe('One.');
    expect(settled).toBe('One.');
  });
});

describe('spans never reach the document', () => {
  it('leaves no trace in the saved markdown', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'The AI wrote this.'));
    expect(ed.getMarkdown()).toBe('One. The AI wrote this. Three.');
  });

  it('renders as a decoration the document does not contain', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'The AI wrote this.'));
    expect(ed.view.dom.querySelector('.richtext-provenance-ai')).not.toBe(null);
    expect(ed.view.state.doc.textContent).toBe('One. The AI wrote this. Three.');
  });
});

describe('a transaction with several steps', () => {
  // Each step's map is expressed in the coordinates of the document BEFORE that
  // step, so comparing every step against the span's ORIGINAL position is wrong as
  // soon as a transaction has more than one. Normalisation emits several at once.
  it('notices an edit inside the span even after an earlier step moved it', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);

    const tr = ed.view.state.tr;
    tr.insertText('XXXXXXXX', 1);              // shifts the span right by 8
    tr.insertText('!', written.from + 8 + 4);  // lands INSIDE the shifted span
    ed.view.dispatch(tr);

    expect(provenanceSpans(ed.view.state), 'the edit inside the span was missed').toHaveLength(0);
  });

  it('still keeps a span when both steps fall outside it', () => {
    const ed = open('One. The AI wrote this. Three.');
    const written = span(ed, 'The AI wrote this.');
    record(ed, written);

    const tr = ed.view.state.tr;
    tr.insertText('XX', 1);
    tr.insertText('YY', ed.view.state.doc.content.size - 1);
    ed.view.dispatch(tr);

    const [survived] = provenanceSpans(ed.view.state);
    expect(provenanceText(ed.view.state.doc, survived)).toBe('The AI wrote this.');
  });
});

describe('formatting commands do not destroy provenance they did not touch', () => {
  it('survives quoting and unquoting the same text', () => {
    // Unwrapping by replacing the whole blockquote maps every position inside to
    // its boundary, so the text came back identical and its span did not.
    const ed = open('The AI wrote this.');
    record(ed, span(ed, 'The AI wrote this.'));

    toggleBlockquote(ed.view.state, ed.view.dispatch, ed.view);
    expect(ed.getMarkdown()).toBe('> The AI wrote this.');
    toggleBlockquote(ed.view.state, ed.view.dispatch, ed.view);
    expect(ed.getMarkdown()).toBe('The AI wrote this.');

    const [survived] = provenanceSpans(ed.view.state);
    expect(survived, 'the span was dissolved by formatting that changed no text').toBeDefined();
    expect(provenanceText(ed.view.state.doc, survived)).toBe('The AI wrote this.');
  });

  it('survives bolding a word inside it', () => {
    const ed = open('One. The AI wrote this. Three.');
    record(ed, span(ed, 'The AI wrote this.'));
    const at = span(ed, 'wrote');
    ed.view.dispatch(ed.view.state.tr.addMark(at.from, at.to, ed.view.state.schema.marks.strong.create()));
    const [survived] = provenanceSpans(ed.view.state);
    expect(survived).toBeDefined();
  });
});
