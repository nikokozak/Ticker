// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { DocumentSession, type SaveState, type SessionTransport } from './session';
import { addProvenanceSpans, hashProvenanceText, provenanceSpans, spanFromJSON, type ProvenanceSpan, type ProvenanceSpanJSON } from './provenance';

/**
 * These are the rules that corrupt a user's notes when they are wrong, so they are
 * tested directly rather than through a component.
 */

let editor: RichTextEditor | null = null;
let session: DocumentSession | null = null;

interface Harness {
  ed: RichTextEditor;
  session: DocumentSession;
  saves: Array<{ markdown: string; baseRevision: number; spans: ProvenanceSpanJSON[] }>;
  reloads: string[];
  states: SaveState[];
  errors: string[];
  failNextSave(reason?: string): void;
}

function open(markdown: string, revision = 1, spans: ProvenanceSpan[] = []): Harness {
  const parent = document.createElement('div');
  document.body.appendChild(parent);

  const saves: Harness['saves'] = [];
  const reloads: string[] = [];
  const states: SaveState[] = [];
  const errors: string[] = [];
  let failure: string | null = null;
  let revisionCounter = revision;

  const transport: SessionTransport = {
    async save(request) {
      saves.push({ markdown: request.markdown, baseRevision: request.baseRevision, spans: request.spans });
      if (failure) {
        const reason = failure;
        failure = null;
        throw new Error(reason);
      }
      revisionCounter += 1;
      return { revision: revisionCounter };
    },
    reload: (streamId) => reloads.push(streamId),
    onSaveStateChange: (state) => states.push(state),
    onError: (message) => errors.push(message),
  };

  editor = createRichTextEditor({
    parent,
    markdown,
    onChange: () => session?.documentChanged(),
  });
  session = new DocumentSession({
    streamId: 'stream-1', editor, transport, revision, spans, autosaveDelay: 5,
  });
  return {
    ed: editor,
    session,
    saves,
    reloads,
    states,
    errors,
    failNextSave: (reason = 'offline') => { failure = reason; },
  };
}

afterEach(() => {
  session?.destroy();
  editor?.destroy();
  session = null;
  editor = null;
  document.body.innerHTML = '';
});

const type = (ed: RichTextEditor, text: string) => ed.view.dispatch(ed.view.state.tr.insertText(text, 1));

describe('autosave', () => {
  it('writes once after a burst of typing, not once per keystroke', async () => {
    const h = open('start');
    type(h.ed, 'a');
    type(h.ed, 'b');
    type(h.ed, 'c');
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].markdown).toBe('cbastart');
  });

  it('does not write when the document has not changed', async () => {
    const h = open('start');
    await h.session.saveNow();
    expect(h.saves).toHaveLength(0);
    expect(h.session.saveState).toBe('saved');
  });

  it('reports saving then saved', async () => {
    const h = open('start');
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.states).toEqual(['saving', 'saved']);
  });

  it('keeps the edits and says so when a write fails', async () => {
    const h = open('start');
    h.failNextSave();
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.session.saveState).toBe('error');
    expect(h.errors[0]).toMatch(/still in the editor/);
    expect(h.ed.getMarkdown()).toBe('xstart'); // nothing was thrown away
  });

  it('sends the revision it holds, and adopts the one it gets back', async () => {
    const h = open('start', 7);
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.saves[0].baseRevision).toBe(7);
    expect(h.session.currentRevision).toBe(8);
  });

  it('reads the document when the write RUNS, not when it was queued', async () => {
    // A queued save that captured its text early would write a stale snapshot
    // against a newer revision, erasing whatever arrived in between.
    const h = open('start');
    type(h.ed, 'x');
    const first = h.session.saveNow();
    type(h.ed, 'y');
    await first;
    await h.session.saveNow();
    expect(h.saves[h.saves.length - 1].markdown).toBe(h.ed.getMarkdown());
  });
});

describe('an append from outside the editor', () => {
  it('adds the fragment and adopts the revision', () => {
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nfrom the quick panel', revision: 4 });
    expect(h.ed.getMarkdown()).toBe('first\n\nfrom the quick panel');
    expect(h.session.currentRevision).toBe(4);
  });

  it('does not then re-save the identical document', async () => {
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 4 });
    await h.session.saveNow();
    expect(h.saves).toHaveLength(0);
  });

  it('reloads instead of patching when a revision is MISSING', () => {
    // The dangerous case. Patching this fragment in and adopting revision 9 would
    // make the next save pass the revision check and silently erase whatever
    // arrived in revisions 4 through 8.
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nlatest', revision: 9 });
    expect(h.reloads).toEqual(['stream-1']);
    expect(h.ed.getMarkdown()).toBe('first'); // untouched
    expect(h.session.currentRevision).toBe(3);
  });

  it('ignores an append meant for another stream', () => {
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'other', fragment: '\n\nnope', revision: 4 });
    expect(h.ed.getMarkdown()).toBe('first');
  });
});

describe('a conflict', () => {
  it('takes the host copy, because it holds work this editor never saw', () => {
    const h = open('mine', 3);
    type(h.ed, 'x');
    h.session.documentConflict({ streamId: 'stream-1', markdown: 'theirs, with more', revision: 11 });
    expect(h.ed.getMarkdown()).toBe('theirs, with more');
    expect(h.session.currentRevision).toBe(11);
  });

  it('does not immediately write the document it was just given', async () => {
    const h = open('mine', 3);
    h.session.documentConflict({ streamId: 'stream-1', markdown: 'theirs', revision: 11 });
    await h.session.saveNow();
    expect(h.saves).toHaveLength(0);
  });
});

describe('provenance travels with the document', () => {
  function spanFor(ed: RichTextEditor, text: string): ProvenanceSpan {
    let at = -1;
    ed.view.state.doc.descendants((node, pos) => {
      if (at < 0 && node.isText && node.text?.includes(text)) at = pos + node.text.indexOf(text);
    });
    const range = { from: at, to: at + text.length };
    return {
      spanId: 'span-1',
      ...range,
      origin: 'ai',
      meta: {},
      textHash: hashProvenanceText(ed.view.state.doc, range),
      createdAt: 0,
    };
  }

  it('is saved alongside the markdown', async () => {
    const h = open('One. The AI wrote this. Three.');
    h.ed.view.dispatch(addProvenanceSpans(h.ed.view.state.tr, [spanFor(h.ed, 'The AI wrote this.')]));
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.saves[0].spans).toHaveLength(1);
  });

  it('is saved with positions that match the SAVED markdown', async () => {
    // The bug this ordering exists to prevent: spans recorded against the live
    // document while a different document is what gets stored.
    const h = open('One.');
    const end = h.ed.view.state.doc.content.size - 1;
    h.ed.view.dispatch(h.ed.view.state.tr.insert(end, [
      h.ed.view.state.schema.nodes.paragraph.create(), // an empty paragraph, which is not storable
      h.ed.view.state.schema.nodes.paragraph.create(null, h.ed.view.state.schema.text('The AI wrote this.')),
    ]));
    h.ed.view.dispatch(addProvenanceSpans(h.ed.view.state.tr, [spanFor(h.ed, 'The AI wrote this.')]));
    await h.session.saveNow();

    const [saved] = h.saves[0].spans;
    const reloaded = open(h.saves[0].markdown, 2, [spanFromJSON(saved)]);
    expect(provenanceSpans(reloaded.ed.view.state)).toHaveLength(1);
    const [restored] = provenanceSpans(reloaded.ed.view.state);
    expect(reloaded.ed.view.state.doc.textBetween(restored.from, restored.to)).toBe('The AI wrote this.');
  });

  it('refuses a span whose text changed while the editor was not looking', () => {
    const h = open('One. The AI wrote this. Three.');
    const stale = { ...spanFor(h.ed, 'The AI wrote this.'), textHash: 'not-the-hash' };
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'One. The AI wrote this. Three.', revision: 5, spans: [stale],
    });
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
  });

  it('restores a span whose text is intact', () => {
    const h = open('One. The AI wrote this. Three.');
    const span = spanFor(h.ed, 'The AI wrote this.');
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'One. The AI wrote this. Three.', revision: 5, spans: [span],
    });
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(1);
  });
});

describe('flushing before the window closes', () => {
  it('writes immediately rather than waiting out the autosave delay', async () => {
    // Nothing here advances time; if the flush waited for the debounce to fire,
    // the write would not have happened by the time saveNow resolves.
    const h = open('start');
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
  });

  it('resolves only once the write has actually happened', async () => {
    const h = open('start');
    type(h.ed, 'x');
    await h.session.saveNow();
    expect(h.session.saveState).toBe('saved');
    expect(h.session.currentRevision).toBe(2);
  });
});
