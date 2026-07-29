// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { DocumentSession, type SaveState, type SessionTransport } from './session';
import { addProvenanceSpans, hashProvenanceText, provenanceSpans, spanFromJSON, type ProvenanceSpan, type ProvenanceSpanJSON } from './provenance';
import { fnv1a } from '../utils/fnv1a';

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

describe('an append landing on unsaved edits', () => {
  it('does not call the merged document saved', async () => {
    // The reproduction: type, receive an append, flush. The editor said "saved"
    // and wrote nothing, while the database held only the appended text — the
    // local edit was gone. lastSaved had been set to a document containing work
    // that was never persisted.
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nREMOTE', revision: 4 });

    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].markdown).toBe('LOCAL base\n\nREMOTE');
    expect(h.saves[0].baseRevision).toBe(4); // against the revision the append made
  });

  it('still avoids a pointless write when there were no local edits', async () => {
    const h = open('base', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nREMOTE', revision: 4 });
    await h.session.saveNow();
    expect(h.saves).toHaveLength(0);
  });
});

describe('provenance that arrives with an append', () => {
  it('is installed at the right place and survives the next save', async () => {
    // The host cannot know a ProseMirror position — it would have to parse the
    // document — so it sends positions relative to the FRAGMENT. Dropping them,
    // which is what happened before, meant the next save replaced the whole stored
    // span set and erased the append's provenance, orphaning its AI exchange.
    const h = open('existing text', 3);
    const fragment = '\n\nThe AI appended this.';
    // Positions inside the parsed fragment: 1 opens its paragraph.
    const spans = [{
      spanId: 'appended-1', start: 1, end: 1 + 'The AI appended this.'.length,
      origin: 'ai', requestId: 'req-1', meta: '{}',
      textHash: fnv1a('The AI appended this.'), createdAt: new Date(0).toISOString(),
    }];

    h.session.documentAppended({ streamId: 'stream-1', fragment, revision: 4, spans });

    const installed = provenanceSpans(h.ed.view.state);
    expect(installed, 'append provenance was dropped').toHaveLength(1);
    expect(h.ed.view.state.doc.textBetween(installed[0].from, installed[0].to)).toBe('The AI appended this.');

    type(h.ed, 'edit ');
    await h.session.saveNow();
    expect(h.saves[0].spans.map((span) => span.spanId)).toContain('appended-1');
  });

  it('refuses a span whose text does not match what arrived', () => {
    const h = open('existing text', 3);
    h.session.documentAppended({
      streamId: 'stream-1', fragment: '\n\nappended', revision: 4,
      spans: [{
        spanId: 'bad', start: 1, end: 9, origin: 'ai', meta: '{}',
        textHash: 'wrong', createdAt: new Date(0).toISOString(),
      }],
    });
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
  });
});

describe('leaving the page inside the autosave delay', () => {
  it('writes the edit instead of dropping it', async () => {
    // Type and immediately click Back. destroy() used to just clear the timer, so
    // the edit was never written and was simply gone on reopening.
    const h = open('start');
    type(h.ed, 'x');
    await h.session.destroy();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].markdown).toBe('xstart');
  });

  it('writes nothing when there is nothing to write', async () => {
    const h = open('start');
    await h.session.destroy();
    expect(h.saves).toHaveLength(0);
  });
});

describe('metadata is part of being dirty', () => {
  it('saves when provenance changes but the text does not', async () => {
    // Dissolving a span changes no text. Comparing markdown alone made the save
    // return early, so the dismissed span came back on reload.
    const h = open('One. The AI wrote this. Three.');
    let at = -1;
    h.ed.view.state.doc.descendants((node, pos) => {
      if (at < 0 && node.isText && node.text?.includes('The AI wrote this.')) at = pos + node.text.indexOf('The AI wrote this.');
    });
    const range = { from: at, to: at + 'The AI wrote this.'.length };
    h.ed.view.dispatch(addProvenanceSpans(h.ed.view.state.tr, [{
      spanId: 's1', ...range, origin: 'ai', meta: {},
      textHash: hashProvenanceText(h.ed.view.state.doc, range), createdAt: 0,
    }]));
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].spans).toHaveLength(1);
  });
});

describe('a save that finishes after the document moved on', () => {
  /**
   * A save that is genuinely IN FLIGHT — the transport has been called and has not
   * answered yet. Waiting on `started` matters: the queue defers the write to a
   * microtask, so anything dispatched immediately after saveNow() would otherwise
   * land before the write even began and the test would pass for the wrong reason.
   */
  function openWithHeldSave(markdown: string, revision: number) {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const saves: string[] = [];
    let announceStart: () => void = () => {};
    const started = new Promise<void>((resolve) => { announceStart = resolve; });
    let release: (value: { revision: number }) => void = () => {};
    let held = true;

    editor = createRichTextEditor({ parent, markdown, onChange: () => session?.documentChanged() });
    session = new DocumentSession({
      streamId: 'stream-1',
      editor,
      revision,
      autosaveDelay: 5,
      transport: {
        save: (request) => {
          saves.push(request.markdown);
          if (!held) return Promise.resolve({ revision: revision + saves.length });
          held = false;
          announceStart();
          return new Promise((resolve) => { release = resolve; });
        },
        reload: () => {},
      },
    });

    return { ed: editor, session, saves, started, release: (r: number) => release({ revision: r }) };
  }

  it('does not drag the revision backwards', async () => {
    // A save goes out at revision 3. While it is in flight a conflict replaces the
    // document at revision 11. The save then answers with revision 4 — the number
    // it produced for a document that no longer exists. Adopting it would make the
    // next save claim a base of 4 against a store at 11, and the revision check
    // would reject every write from then on.
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'x');
    const inFlight = h.session.saveNow();
    await h.started;

    // Prefix-provable, so the conflict merges and adopts revision 11.
    h.session.documentConflict({ streamId: 'stream-1', markdown: 'start\n\nfrom the host', revision: 11 });
    h.release(4);
    await inFlight;

    expect(h.session.currentRevision).toBe(11);
    expect(h.ed.getMarkdown()).toBe('xstart\n\nfrom the host');
  });

  it('does not mark the superseded document as the saved one', async () => {
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'x');
    const inFlight = h.session.saveNow();
    await h.started;

    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 4 });
    h.release(4);
    await inFlight;

    // The local edit plus the append is unsaved work; the session must still know.
    await h.session.saveNow();
    expect(h.saves[h.saves.length - 1]).toBe('xstart\n\nappended');
  });
});

describe('a conflict', () => {
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

describe('a conflict arriving on top of unsaved work', () => {
  it('keeps the local edit and merges what the host added', async () => {
    // Type a sentence, lose the revision race to a quick-panel capture. Taking the
    // host copy wholesale — which is what "host wins" did — deletes the sentence.
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'base\n\nfrom the quick panel', revision: 4,
    });

    expect(h.ed.getMarkdown()).toBe('LOCAL base\n\nfrom the quick panel');
    await h.session.saveNow();
    expect(h.saves[0].markdown).toBe('LOCAL base\n\nfrom the quick panel');
    expect(h.saves[0].baseRevision).toBe(4);
  });

  it('keeps the local text when the two genuinely diverged', async () => {
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'something else entirely', revision: 4,
    });

    expect(h.ed.getMarkdown()).toBe('LOCAL base'); // nothing thrown away
    expect(h.session.saveState).toBe('error');
    expect(h.errors[0]).toMatch(/still here/);
  });

  it('still takes the host copy when nothing local is pending', () => {
    const h = open('base', 3);
    h.session.documentConflict({ streamId: 'stream-1', markdown: 'the host copy', revision: 9 });
    expect(h.ed.getMarkdown()).toBe('the host copy');
    expect(h.session.currentRevision).toBe(9);
  });
});

describe('a save whose reply is delayed past an append', () => {
  it('is rejected even though nothing bumped the generation in between', async () => {
    // The gap a generation counter alone leaves: the save wins at revision 4, its
    // reply is delayed, an external append takes revision 5, and the stale reply
    // then claims revision 4 — older than the store.
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    let release: (value: { revision: number }) => void = () => {};
    let announceStart: () => void = () => {};
    const started = new Promise<void>((resolve) => { announceStart = resolve; });

    editor = createRichTextEditor({ parent, markdown: 'start', onChange: () => session?.documentChanged() });
    session = new DocumentSession({
      streamId: 'stream-1',
      editor,
      revision: 3,
      autosaveDelay: 5,
      transport: {
        save: () => { announceStart(); return new Promise((resolve) => { release = resolve; }); },
        reload: () => {},
      },
    });

    type(editor, 'x');
    const inFlight = session.saveNow();
    await started;

    session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 4 });
    release({ revision: 4 });
    await inFlight;

    expect(session.currentRevision).toBe(4);
    expect(editor.getMarkdown()).toBe('xstart\n\nappended'); // nothing lost
  });
});

describe('reporting whether the document is actually stored', () => {
  it('says so when the write failed', async () => {
    // Acknowledging a flush that did not save means the host closes the window or
    // quits, throwing away the only copy of what was typed.
    const h = open('start');
    h.failNextSave();
    type(h.ed, 'x');
    expect(await h.session.saveNow()).toBe(false);
  });

  it('says so when the write succeeded', async () => {
    const h = open('start');
    type(h.ed, 'x');
    expect(await h.session.saveNow()).toBe(true);
  });

  it('reports success when there was nothing to write', async () => {
    const h = open('start');
    expect(await h.session.saveNow()).toBe(true);
    expect(await h.session.destroy()).toBe(true);
  });

  it('reports failure from destroy, so leaving the page can warn', async () => {
    const h = open('start');
    h.failNextSave();
    type(h.ed, 'x');
    expect(await h.session.destroy()).toBe(false);
    expect(h.ed.getMarkdown()).toBe('xstart'); // still there to recover
  });
});
