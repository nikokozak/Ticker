// @vitest-environment jsdom
import { TextSelection } from 'prosemirror-state';
import { afterEach, describe, expect, it } from 'vitest';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { parseMarkdown } from './markdown';
import { DocumentSession, type SaveState, type SessionTransport } from './session';
import { addProvenanceSpans, hashProvenanceText, provenanceSpans, spanFromJSON, type ProvenanceSpan, type ProvenanceSpanJSON } from './provenance';
import { fnv1a } from '../utils/fnv1a';
import type { PendingAppend } from './pendingAppends';
import type { InboxAppend } from './inbox';

/**
 * These are the rules that corrupt a user's notes when they are wrong, so they are
 * tested directly rather than through a component.
 */

let editor: RichTextEditor | null = null;
let session: DocumentSession | null = null;

const canonical = (markdown: string) => ({
  docJSON: JSON.stringify(parseMarkdown(markdown).toJSON()),
  docFormatVersion: 1 as const,
  markdown,
});

interface Harness {
  ed: RichTextEditor;
  session: DocumentSession;
  saves: Array<{
    docJSON: string;
    docFormatVersion: number;
    markdown: string;
    baseRevision: number;
    spans: ProvenanceSpanJSON[];
    resolvedPendingThrough?: number;
    consumedInboxThrough?: number;
  }>;
  reloads: string[];
  states: SaveState[];
  errors: string[];
  failNextSave(reason?: string): void;
}

function open(
  markdown: string,
  revision = 1,
  spans: ProvenanceSpan[] = [],
  pendingAppends: PendingAppend[] = [],
  inboxAppends: InboxAppend[] = [],
): Harness {
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
      saves.push({
        docJSON: request.docJSON,
        docFormatVersion: request.docFormatVersion,
        markdown: request.markdown,
        baseRevision: request.baseRevision,
        spans: request.spans,
        resolvedPendingThrough: request.resolvedPendingThrough,
        consumedInboxThrough: request.consumedInboxThrough,
      });
      if (failure) {
        const reason = failure;
        failure = null;
        throw new Error(reason);
      }
      // What the store actually does: a save is accepted against the revision it
      // names and produces the next one. Counting from the opening revision instead
      // made the harness answer with a stale number after any external append, and
      // the session — correctly — rejected it.
      revisionCounter = request.baseRevision + 1;
      return { revision: revisionCounter };
    },
    reload: (streamId) => reloads.push(streamId),
    onSaveStateChange: (state) => states.push(state),
    onError: (message) => errors.push(message),
  };

  editor = createRichTextEditor({
    parent,
    docJSON: canonical(markdown).docJSON,
    onChange: () => session?.documentChanged(),
  });
  session = new DocumentSession({
    streamId: 'stream-1',
    editor,
    transport,
    revision,
    spans,
    pendingAppends,
    inboxAppends,
    autosaveDelay: 5,
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

/**
 * What the host ACTUALLY sends. Every producer records offsets into the
 * fragment's own markdown, from 0 to its length, hashed over that raw markdown.
 * It cannot send ProseMirror positions without parsing the document.
 */
const wireSpan = (fragment: string, overrides: Partial<ProvenanceSpanJSON> = {}): ProvenanceSpanJSON => ({
  spanId: 'appended-1',
  start: 0,
  end: fragment.length,
  origin: 'ai',
  requestId: 'req-1',
  meta: '{}',
  textHash: fnv1a(fragment),
  createdAt: new Date(0).toISOString(),
  ...overrides,
});

const pendingAppend = (
  revision: number,
  fragment: string,
  rawSpans: ProvenanceSpanJSON[] = [],
  separator = '\n\n',
): PendingAppend => ({ revision, separator, fragment, rawSpans });

const inboxAppend = (
  seq: number,
  fragment: string,
  rawSpans: ProvenanceSpanJSON[] = [],
): InboxAppend => ({
  seq,
  appendId: `append-${seq}`,
  fragment,
  rawSpansJSON: JSON.stringify(rawSpans),
  createdAt: new Date(0).toISOString(),
});

describe('the durable append inbox', () => {
  it('does not rebuild editor state when there are no inbox rows', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    editor = createRichTextEditor({ parent, docJSON: canonical('Base.').docJSON });
    const before = editor.view.state;
    session = new DocumentSession({
      streamId: 'stream-1',
      editor,
      revision: 1,
      transport: { save: async () => ({ revision: 2 }), reload: () => {} },
    });

    expect(editor.view.state).toBe(before);
  });

  it('reduces every row before saving the document and its placed provenance', async () => {
    const fragment = '**Captured.**';
    const h = open('Base.', 7, [], [], [
      inboxAppend(9, fragment, [wireSpan(fragment)]),
      inboxAppend(3, 'First.'),
    ]);

    expect(h.ed.getMarkdownProjection()).toBe('Base.\n\nFirst.\n\n**Captured.**');
    const [span] = provenanceSpans(h.ed.view.state);
    expect(h.ed.view.state.doc.textBetween(span.from, span.to)).toBe('Captured.');

    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].consumedInboxThrough).toBe(9);
  });

  it('leaves the live document untouched when one row is malformed', () => {
    const h = open('Base.', 7, [], [], [
      inboxAppend(3, 'First.'),
      { ...inboxAppend(9, 'Second.'), rawSpansJSON: '{"bad":true}' },
    ]);

    expect(h.ed.getMarkdownProjection()).toBe('Base.');
    expect(h.session.saveState).toBe('error');
    expect(h.saves).toHaveLength(0);
    expect(h.errors[0]).toMatch(/additions/);
  });

  it('does not send an already-consumed watermark on the next save', async () => {
    const h = open('Base.', 7, [], [], [inboxAppend(3, 'Captured.')]);

    await h.session.saveNow();
    type(h.ed, 'Local ');
    await h.session.saveNow();

    expect(h.saves.map((save) => save.consumedInboxThrough)).toEqual([3, undefined]);
  });

  it('reduces rows that arrive with a reloaded canonical document', async () => {
    const h = open('Old.', 1);
    h.session.documentLoaded({
      ...canonical('Host.'),
      revision: 2,
      inboxAppends: [inboxAppend(12, 'Queued.')],
    });

    expect(h.ed.getMarkdownProjection()).toBe('Host.\n\nQueued.');
    await h.session.saveNow();
    expect(h.saves[0].consumedInboxThrough).toBe(12);
  });
});

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
    expect(h.ed.getMarkdownProjection()).toBe('xstart'); // nothing was thrown away
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
    expect(h.saves[h.saves.length - 1].markdown).toBe(h.ed.getMarkdownProjection());
  });
});

describe('an append from outside the editor', () => {
  it('adds the fragment and adopts the revision', () => {
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nfrom the quick panel', revision: 4 });
    expect(h.ed.getMarkdownProjection()).toBe('first\n\nfrom the quick panel');
    expect(h.session.currentRevision).toBe(4);
  });

  it('saves once, to let the store forget the append it recorded', async () => {
    // The text is already stored — the append is what put it there — so this write
    // exists for the ROW. Every append records one, and only an editor that has
    // taken its provenance into the document may say it can be forgotten. Left
    // behind, the row outlives the revision it was recorded at, and a replay that
    // peels fragments off the END of the document can never use it again.
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: 'appended', revision: 4 });
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].markdown).toBe('first\n\nappended');
    expect(h.saves[0].resolvedPendingThrough).toBe(4);
  });

  it('reloads instead of patching when a revision is MISSING', () => {
    // The dangerous case. Patching this fragment in and adopting revision 9 would
    // make the next save pass the revision check and silently erase whatever
    // arrived in revisions 4 through 8.
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nlatest', revision: 9 });
    expect(h.reloads).toEqual(['stream-1']);
    expect(h.ed.getMarkdownProjection()).toBe('first'); // untouched
    expect(h.session.currentRevision).toBe(3);
  });

  it('ignores an append meant for another stream', () => {
    const h = open('first', 3);
    h.session.documentAppended({ streamId: 'other', fragment: '\n\nnope', revision: 4 });
    expect(h.ed.getMarkdownProjection()).toBe('first');
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

  it('writes the append itself back exactly once', async () => {
    const h = open('base', 3);
    h.session.documentAppended({ streamId: 'stream-1', fragment: 'REMOTE', revision: 4 });
    await h.session.saveNow();
    // One write, to clear the append's row; then nothing more to say.
    expect(h.saves).toHaveLength(1);
    await h.session.saveNow();
    expect(h.saves).toHaveLength(1);
  });
});

describe('provenance that arrives with an append', () => {
  it('is installed at the right place and survives the next save', async () => {
    // Dropping it, which is what happened before, meant the next save replaced the
    // whole stored span set and erased the append's provenance, orphaning its AI
    // exchange.
    const h = open('existing text', 3);
    const fragment = 'The AI appended this.';

    h.session.documentAppended({ streamId: 'stream-1', fragment, revision: 4, spans: [wireSpan(fragment)] });

    const installed = provenanceSpans(h.ed.view.state);
    expect(installed, 'append provenance was dropped').toHaveLength(1);
    expect(h.ed.view.state.doc.textBetween(installed[0].from, installed[0].to)).toBe('The AI appended this.');

    type(h.ed, 'edit ');
    await h.session.saveNow();
    expect(h.saves[0].spans.map((span) => span.spanId)).toContain('appended-1');
  });

  it('places it over the text, not over the markup', () => {
    // The offsets are into MARKDOWN, so a fragment with any formatting has more
    // characters than the document does. Reading them as positions would land the
    // highlight past the end of what was appended.
    const h = open('existing text', 3);
    const fragment = 'The **AI** appended this.';
    h.session.documentAppended({ streamId: 'stream-1', fragment, revision: 4, spans: [wireSpan(fragment)] });

    const [installed] = provenanceSpans(h.ed.view.state);
    expect(installed, 'append provenance was dropped').toBeDefined();
    expect(h.ed.view.state.doc.textBetween(installed.from, installed.to)).toBe('The AI appended this.');
    // Rehashed over the document text: the markdown hash would never match again.
    expect(installed.textHash).toBe(fnv1a('The AI appended this.'));
  });

  it('does not let the store forget a row whose spans it could not place', async () => {
    // Half a conversion is worse than none: the save that follows would clear the
    // row, so what could not be placed is gone rather than merely deferred.
    const h = open('existing text', 3);
    const fragment = 'one\n\ntwo';
    h.session.documentAppended({
      streamId: 'stream-1',
      fragment,
      revision: 4,
      spans: [wireSpan(fragment), wireSpan(fragment, { spanId: 'appended-2', textHash: 'drifted' })],
    });

    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
    type(h.ed, 'edit ');
    await h.session.saveNow();
    // Still 3 — what it knew before the append. It must not reach 4, because the
    // store deletes everything at or below what it is told.
    expect(h.saves[0].resolvedPendingThrough).toBe(3);
  });

  it('refuses a span whose text does not match what arrived', () => {
    const h = open('existing text', 3);
    h.session.documentAppended({
      streamId: 'stream-1', fragment: 'appended', revision: 4,
      spans: [{
        spanId: 'bad', start: 0, end: 8, origin: 'ai', meta: '{}',
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
  function openWithHeldSave(
    markdown: string,
    revision: number,
    inboxAppends: InboxAppend[] = [],
  ) {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const saves: string[] = [];
    const inboxWatermarks: Array<number | undefined> = [];
    let announceStart: () => void = () => {};
    const started = new Promise<void>((resolve) => { announceStart = resolve; });
    let release: (value: { revision: number }) => void = () => {};
    let held = true;
    let failNext = false;

    editor = createRichTextEditor({
      parent,
      docJSON: canonical(markdown).docJSON,
      onChange: () => session?.documentChanged(),
    });
    session = new DocumentSession({
      streamId: 'stream-1',
      editor,
      revision,
      autosaveDelay: 5,
      transport: {
        save: (request) => {
          saves.push(request.markdown);
          inboxWatermarks.push(request.consumedInboxThrough);
          if (!held) {
            if (failNext) { failNext = false; return Promise.reject(new Error('offline')); }
            return Promise.resolve({ revision: revision + saves.length });
          }
          held = false;
          announceStart();
          return new Promise((resolve) => { release = resolve; });
        },
        reload: () => {},
      },
      inboxAppends,
    });

    return {
      ed: editor,
      session,
      saves,
      inboxWatermarks,
      started,
      release: (r: number) => release({ revision: r }),
      failNextSave: () => { failNext = true; },
    };
  }

  it('does not clear a newer inbox watermark when an older save answers', async () => {
    const h = openWithHeldSave('Base.', 7, [inboxAppend(3, 'First.')]);
    const inFlight = h.session.saveNow();
    await h.started;

    h.session.documentLoaded({
      ...canonical('Host.'),
      revision: 8,
      inboxAppends: [inboxAppend(9, 'Second.')],
    });
    h.release(8);
    await inFlight;

    expect(h.inboxWatermarks).toEqual([3, 9]);
  });

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

    // The pending rows prove both appends, so the conflict adopts revision 5.
    h.session.documentConflict({
      streamId: 'stream-1',
      markdown: 'start\n\nfrom four\n\nfrom five',
      revision: 5,
      pendingAppends: [pendingAppend(4, 'from four'), pendingAppend(5, 'from five')],
    });
    h.release(4);
    await inFlight;

    expect(h.session.currentRevision).toBe(5);
    expect(h.ed.getMarkdownProjection()).toBe('xstart\n\nfrom four\n\nfrom five');
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

  it('keeps writing until nothing is left, before it answers', async () => {
    // Type, hold the save, type again, release. The first write stores only the
    // first edit — the second arrived while it was in flight and lives nowhere but
    // the editor. Answering the flush here is the host being told it may quit, and
    // the second edit is the copy it then throws away.
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'a');
    const flush = h.session.saveNow();
    await h.started;
    type(h.ed, 'b');
    h.release(4);

    expect(await flush).toBe(true);
    expect(h.saves[h.saves.length - 1], 'the flush answered before the last edit was written').toBe('bastart');
    expect(h.session.currentRevision).toBe(5);
  });

  it('answers false when it is the second pass that fails', async () => {
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'a');
    const flush = h.session.saveNow();
    await h.started;
    type(h.ed, 'b');
    h.failNextSave();
    h.release(4);

    expect(await flush).toBe(false);
    expect(h.ed.getMarkdownProjection()).toBe('bastart'); // still there to recover
  });
});

describe('a conflict', () => {
  it('does not immediately write the document it was just given', async () => {
    const h = open('mine', 3);
    h.session.documentConflict({
      streamId: 'stream-1',
      ...canonical('theirs'),
      revision: 11,
    });
    await h.session.saveNow();
    expect(h.saves).toHaveLength(0);
    expect(h.ed.getMarkdownProjection()).toBe('theirs');
  });

  it.each([
    ['an unsupported version', { ...canonical('theirs'), docFormatVersion: 2 }],
    ['malformed JSON', { ...canonical('theirs'), docJSON: '{not json' }],
  ])('keeps the live document when a reload carries %s', (_label, payload) => {
    const h = open('mine', 3);

    h.session.documentLoaded({ ...payload, revision: 11 });

    expect(h.ed.getMarkdownProjection()).toBe('mine');
    expect(h.session.currentRevision).toBe(3);
    expect(h.session.saveState).toBe('error');
    expect(h.errors[0]).toMatch(/left untouched/);
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

  it('treats a blank paragraph as a document change even when markdown cannot', async () => {
    const h = open('One.');
    const end = h.ed.view.state.doc.content.size - 1;
    h.ed.view.dispatch(h.ed.view.state.tr.insert(
      end,
      h.ed.view.state.schema.nodes.paragraph.create(),
    ));

    await h.session.saveNow();

    expect(h.saves).toHaveLength(1);
    const saved = h.ed.view.state.schema.nodeFromJSON(JSON.parse(h.saves[0].docJSON));
    expect(saved.childCount).toBe(2);
  });

  it('saves a blank paragraph and its positions in canonical document JSON', async () => {
    const h = open('One.');
    const end = h.ed.view.state.doc.content.size - 1;
    h.ed.view.dispatch(h.ed.view.state.tr.insert(end, [
      h.ed.view.state.schema.nodes.paragraph.create(),
      h.ed.view.state.schema.nodes.paragraph.create(null, h.ed.view.state.schema.text('The AI wrote this.')),
    ]));
    h.ed.view.dispatch(addProvenanceSpans(h.ed.view.state.tr, [spanFor(h.ed, 'The AI wrote this.')]));

    await h.session.saveNow();

    expect(h.saves).toHaveLength(1);
    expect(h.saves[0].docFormatVersion).toBe(1);
    const saved = h.ed.view.state.schema.nodeFromJSON(JSON.parse(h.saves[0].docJSON));
    const [savedSpan] = h.saves[0].spans;
    expect(saved.childCount).toBe(3);
    expect(saved.textBetween(savedSpan.start, savedSpan.end)).toBe('The AI wrote this.');
  });

  it('is saved with positions that match the saved document', async () => {
    const h = open('One.');
    const end = h.ed.view.state.doc.content.size - 1;
    h.ed.view.dispatch(h.ed.view.state.tr.insert(end, [
      h.ed.view.state.schema.nodes.paragraph.create(), // an empty paragraph, which is not storable
      h.ed.view.state.schema.nodes.paragraph.create(null, h.ed.view.state.schema.text('The AI wrote this.')),
    ]));
    h.ed.view.dispatch(addProvenanceSpans(h.ed.view.state.tr, [spanFor(h.ed, 'The AI wrote this.')]));
    await h.session.saveNow();

    const [saved] = h.saves[0].spans;
    const reloaded = open('placeholder', 2, [spanFromJSON(saved)]);
    reloaded.ed.setDocumentJSON(h.saves[0].docJSON);
    reloaded.session.documentLoaded({
      docJSON: h.saves[0].docJSON,
      docFormatVersion: 1,
      markdown: h.saves[0].markdown,
      revision: 2,
      spans: [spanFromJSON(saved)],
    });
    expect(provenanceSpans(reloaded.ed.view.state)).toHaveLength(1);
    const [restored] = provenanceSpans(reloaded.ed.view.state);
    expect(reloaded.ed.view.state.doc.textBetween(restored.from, restored.to)).toBe('The AI wrote this.');
  });

  it('refuses a span whose text changed while the editor was not looking', () => {
    const h = open('One. The AI wrote this. Three.');
    const stale = { ...spanFor(h.ed, 'The AI wrote this.'), textHash: 'not-the-hash' };
    h.session.documentConflict({
      streamId: 'stream-1',
      ...canonical('One. The AI wrote this. Three.'),
      revision: 5,
      spans: [stale],
    });
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
  });

  it('restores a span whose text is intact', () => {
    const h = open('One. The AI wrote this. Three.');
    const span = spanFor(h.ed, 'The AI wrote this.');
    h.session.documentConflict({
      streamId: 'stream-1',
      ...canonical('One. The AI wrote this. Three.'),
      revision: 5,
      spans: [span],
    });
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(1);
  });

  it('drops an out-of-bounds stored span without throwing during reload', () => {
    const h = open('One.');
    const outside: ProvenanceSpan = {
      spanId: 'outside',
      from: 1,
      to: 999,
      origin: 'ai',
      meta: {},
      textHash: 'irrelevant',
      createdAt: 0,
    };

    expect(() => h.session.documentLoaded({
      ...canonical('One.'),
      revision: 5,
      spans: [outside],
    })).not.toThrow();
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
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
  it('merges a proven append and keeps the local edit unsaved', async () => {
    // Type a sentence, lose the revision race to a quick-panel capture. Taking the
    // host copy wholesale — which is what "host wins" did — deletes the sentence.
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'base\n\nfrom the quick panel', revision: 4,
      pendingAppends: [pendingAppend(4, 'from the quick panel')],
    });

    expect(h.ed.getMarkdownProjection()).toBe('LOCAL base\n\nfrom the quick panel');
    await h.session.saveNow();
    expect(h.saves[0].markdown).toBe('LOCAL base\n\nfrom the quick panel');
    expect(h.saves[0].baseRevision).toBe(4);
    expect(h.saves[0].resolvedPendingThrough).toBe(4);
  });

  it('places the proven append provenance over text, not markup', () => {
    const h = open('base', 3);
    const fragment = 'The **AI** appended this.';
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1',
      ...canonical(`base\n\n${fragment}`),
      revision: 4,
      pendingAppends: [pendingAppend(4, fragment, [wireSpan(fragment)])],
    });

    const [installed] = provenanceSpans(h.ed.view.state);
    expect(installed, 'conflict provenance was dropped').toBeDefined();
    expect(h.ed.view.state.doc.textBetween(installed.from, installed.to)).toBe('The AI appended this.');
    expect(installed.textHash).toBe(fnv1a('The AI appended this.'));
  });

  it('refuses rows that do not start at the next revision', async () => {
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1',
      markdown: 'base\n\nunexplained gap',
      revision: 5,
      pendingAppends: [pendingAppend(5, 'unexplained gap')],
    });

    expect(h.ed.getMarkdownProjection()).toBe('LOCAL base');
    expect(h.session.currentRevision).toBe(3);
    expect(h.session.saveState).toBe('error');
    expect(h.errors[0]).toMatch(/still here/);

    // A refused row is still the store's to keep. Claiming revision 5 here would
    // delete every pending row at or below it, including the one just refused.
    h.failNextSave();
    await h.session.saveNow();
    expect(h.saves[0].resolvedPendingThrough).toBe(3);
  });

  it('refuses a host document that the rows cannot peel back to lastSaved', () => {
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1',
      markdown: 'base drifted outside an append\n\nclaimed append',
      revision: 4,
      pendingAppends: [pendingAppend(4, 'claimed append')],
    });

    expect(h.ed.getMarkdownProjection()).toBe('LOCAL base');
    expect(h.session.currentRevision).toBe(3);
    expect(h.session.saveState).toBe('error');
  });

  it('refuses an unplaceable span without touching the document or cursor', () => {
    const h = open('base', 3);
    const fragment = 'The **AI** appended this.';
    type(h.ed, 'LOCAL ');
    h.ed.view.dispatch(h.ed.view.state.tr.setSelection(TextSelection.create(h.ed.view.state.doc, 3)));
    const before = h.ed.getMarkdownProjection();
    const cursor = h.ed.view.state.selection.from;

    h.session.documentConflict({
      streamId: 'stream-1',
      markdown: `base\n\n${fragment}`,
      revision: 4,
      pendingAppends: [pendingAppend(4, fragment, [wireSpan(fragment, { textHash: 'drifted' })])],
    });

    expect(h.ed.getMarkdownProjection()).toBe(before);
    expect(h.ed.view.state.selection.from).toBe(cursor);
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(0);
    expect(h.session.currentRevision).toBe(3);
    expect(h.session.saveState).toBe('error');
  });

  it('keeps the local text when the two genuinely diverged', async () => {
    const h = open('base', 3);
    type(h.ed, 'LOCAL ');
    h.session.documentConflict({
      streamId: 'stream-1', markdown: 'something else entirely', revision: 4,
    });

    expect(h.ed.getMarkdownProjection()).toBe('LOCAL base'); // nothing thrown away
    expect(h.session.saveState).toBe('error');
    expect(h.errors[0]).toMatch(/still here/);
  });

  it('does not let a proven merge clear rows an abandoned replay left behind', async () => {
    // Open on rows that cannot be replayed, so this session has proven nothing and
    // the store must keep them. A later conflict whose OWN rows do prove out must
    // not sweep those away with them: the store deletes every row at or below what
    // it is told, so one number covers both.
    const h = open('base\n\nunreplayable', 4, [], [pendingAppend(4, 'a different fragment')]);
    expect(h.errors[0]).toMatch(/history restored/);
    type(h.ed, 'LOCAL ');

    h.session.documentConflict({
      streamId: 'stream-1',
      markdown: 'base\n\nunreplayable\n\nproven append',
      revision: 5,
      pendingAppends: [pendingAppend(5, 'proven append')],
    });

    // The merge itself is fine — the text arrives and the local edit survives.
    expect(h.ed.getMarkdownProjection()).toBe('LOCAL base\n\nunreplayable\n\nproven append');
    await h.session.saveNow();
    // But nothing may be forgotten, because revision 4's row never was converted.
    expect(h.saves[0].resolvedPendingThrough).toBeUndefined();
  });

  it('still takes the host copy and adopts its pending rows when nothing local is pending', async () => {
    const h = open('base', 3);
    const fragment = 'The **host** appended this.';
    h.session.documentConflict({
      streamId: 'stream-1',
      ...canonical(`base\n\n${fragment}`),
      revision: 4,
      pendingAppends: [pendingAppend(4, fragment, [wireSpan(fragment)])],
    });
    expect(h.ed.getMarkdownProjection()).toBe(`base\n\n${fragment}`);
    expect(h.session.currentRevision).toBe(4);
    expect(provenanceSpans(h.ed.view.state)).toHaveLength(1);
    await h.session.saveNow();
    expect(h.saves[0].resolvedPendingThrough).toBe(4);
  });
});

describe('an append that arrives while a save is in flight', () => {
  /**
   * The order that actually happens, and the one a generation counter alone does
   * not describe: the session holds revision 3 and its save is in flight, so the
   * STORE is already at 4 while the session still says 3. An append then takes 5
   * and is broadcast before the save's reply gets back.
   *
   * Only the first save is held, so a drain's later passes can still complete.
   */
  function openWithHeldSave(markdown: string, revision: number) {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const reloads: string[] = [];
    let announceStart: () => void = () => {};
    const started = new Promise<void>((resolve) => { announceStart = resolve; });
    let release: (value: { revision: number }) => void = () => {};
    let held = true;
    let counter = revision;

    editor = createRichTextEditor({
      parent,
      docJSON: canonical(markdown).docJSON,
      onChange: () => session?.documentChanged(),
    });
    session = new DocumentSession({
      streamId: 'stream-1',
      editor,
      revision,
      autosaveDelay: 5,
      transport: {
        save: () => {
          if (!held) { counter += 1; return Promise.resolve({ revision: counter }); }
          held = false;
          announceStart();
          return new Promise((resolve) => { release = resolve; });
        },
        reload: (id) => reloads.push(id),
      },
    });
    return { ed: editor, session, started, reloads, release: (r: number) => release({ revision: r }) };
  }

  it('asks for a reload rather than patching a fragment it cannot place', async () => {
    // Revision 5 against a session holding 3 means one append is unaccounted for —
    // this one, or an earlier one this editor never heard. Appending the fragment
    // and adopting 5 would make the next save pass the revision check and erase
    // whatever the gap contained.
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'x');
    const inFlight = h.session.saveNow();
    await h.started;

    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 5 });
    expect(h.reloads).toEqual(['stream-1']);
    expect(h.ed.getMarkdownProjection()).toBe('xstart'); // the fragment was NOT patched in

    h.release(4);
    await inFlight;

    // The reply is the session's own save and is still current from where it sits,
    // so it is adopted; the reload it asked for carries it the rest of the way.
    expect(h.session.currentRevision).toBe(4);

    h.session.documentLoaded({ ...canonical('xstart\n\nappended'), revision: 5 });
    expect(h.session.currentRevision).toBe(5);
    expect(h.ed.getMarkdownProjection()).toBe('xstart\n\nappended'); // nothing lost
  });

  it('does not regress the revision when the reload lands before the reply', async () => {
    // Same order, but the reload answers first. The save's reply then describes a
    // document that is gone: adopting revision 4 over 5 would make every later
    // write fail the revision check.
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'x');
    const inFlight = h.session.saveNow();
    await h.started;

    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 5 });
    h.session.documentLoaded({ ...canonical('xstart\n\nappended'), revision: 5 });
    h.release(4);
    await inFlight;

    expect(h.session.currentRevision).toBe(5);
    expect(h.ed.getMarkdownProjection()).toBe('xstart\n\nappended');
  });

  it('merges an append that is exactly the next revision', async () => {
    // The ordinary case, for contrast: no gap, so the fragment is appended here too
    // and the local edit stays unsaved until the next write.
    const h = openWithHeldSave('start', 3);
    type(h.ed, 'x');
    const inFlight = h.session.saveNow();
    await h.started;

    h.session.documentAppended({ streamId: 'stream-1', fragment: '\n\nappended', revision: 4 });
    expect(h.reloads).toEqual([]);
    h.release(4);
    await inFlight;

    expect(h.ed.getMarkdownProjection()).toBe('xstart\n\nappended'); // nothing lost
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
    expect(h.ed.getMarkdownProjection()).toBe('xstart'); // still there to recover
  });
});
