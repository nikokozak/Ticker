import type { RichTextEditor } from './editor';
import { placeFragmentSpan, planReplay, type PendingAppend } from './pendingAppends';
import {
  addProvenanceSpans,
  hashProvenanceText,
  placeAppendedSpans,
  provenanceSpans,
  setProvenanceSpans,
  spanToJSON,
  type ProvenanceSpan,
  type ProvenanceSpanJSON,
} from './provenance';

/**
 * Owning a stream's document: when it is saved, what happens when something else
 * writes to it, and how the two are kept from overwriting each other.
 *
 * Deliberately free of React and of the bridge. The rules here are the ones that
 * corrupt a user's notes when they are wrong, and they are worth testing directly
 * rather than through a component.
 *
 * The invariant everything serves: EVERY external write appends, and the editor
 * saves with a revision check. If the revision the editor holds is stale it has
 * missed an append, and saving would erase it.
 */

export type SaveState = 'saved' | 'saving' | 'error';

export interface SaveResult {
  revision: number;
}

/** What the session needs from the host. Tests supply this directly. */
export interface SessionTransport {
  save(request: {
    streamId: string;
    markdown: string;
    baseRevision: number;
    spans: ProvenanceSpanJSON[];
  }): Promise<SaveResult>;
  /** Ask the host to send the document again, after a gap it cannot reconcile. */
  reload(streamId: string): void;
  onSaveStateChange?(state: SaveState): void;
  onError?(message: string, detail: unknown): void;
}

export interface SessionOptions {
  streamId: string;
  editor: RichTextEditor;
  transport: SessionTransport;
  revision: number;
  spans?: ProvenanceSpan[];
  /** Appends recorded while no editor was open, still in fragment coordinates. */
  pendingAppends?: PendingAppend[];
  /** Milliseconds of quiet before an edit is written. */
  autosaveDelay?: number;
}

const DEFAULT_AUTOSAVE_DELAY = 350;

export class DocumentSession {
  private readonly options: Required<Pick<SessionOptions, 'autosaveDelay'>> & SessionOptions;

  private revision: number;

  private lastSaved: string;

  /** The spans as last persisted, so metadata-only changes still count as dirty. */
  private lastSavedSpans = '';

  private timer: ReturnType<typeof setTimeout> | null = null;

  /** Saves run one at a time; a second edit while one is in flight waits for it. */
  private queue: Promise<void> = Promise.resolve();


  private state: SaveState = 'saved';

  /**
   * Bumped whenever the document is replaced or appended to from outside. A save
   * that answers after its generation has passed is answering about a document
   * that no longer exists, so its revision must not be adopted: doing so left the
   * session claiming a base revision older than the store, and every subsequent
   * write failed the revision check.
   */
  private generation = 0;

  constructor(options: SessionOptions) {
    this.options = { autosaveDelay: DEFAULT_AUTOSAVE_DELAY, ...options };
    this.revision = options.revision;
    this.lastSaved = options.editor.getMarkdown();
    if (options.spans?.length) this.restoreSpans(options.spans);
    this.lastSavedSpans = this.spanFingerprint();
    if (options.pendingAppends?.length) this.convertPendingAppends(options.pendingAppends);
  }

  get saveState(): SaveState {
    return this.state;
  }

  get currentRevision(): number {
    return this.revision;
  }

  /** Call from the editor's onChange. */
  documentChanged(): void {
    this.setState('saving');
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.saveNow();
    }, this.options.autosaveDelay);
  }

  /**
   * Place the provenance of appends that happened while no editor was open.
   *
   * The editor was constructed from the FULL stored markdown, fragments included,
   * so nothing is re-inserted: the document is rebuilt from the base and the
   * fragments are replayed through the same append path, which is what makes each
   * fragment's position knowable.
   *
   * Any proof that fails abandons the whole replay and leaves the rows alone. A
   * half-converted span points at the wrong text and claims the AI wrote something
   * it did not, which is worse than no highlighting; the rows survive, so a later
   * version can still convert them correctly.
   */
  private convertPendingAppends(pending: PendingAppend[]): void {
    const { editor } = this.options;
    const plan = planReplay(this.lastSaved, this.revision, pending);
    if (!plan.ok) {
      this.options.transport.onError?.(
        'Some recent additions could not have their history restored; the text itself is intact.',
        plan.reason,
      );
      return;
    }
    if (!plan.appends.length) return;

    const existing = provenanceSpans(editor.view.state);
    editor.setMarkdown(plan.baseMarkdown);

    const placed: ProvenanceSpan[] = [...existing];
    for (const append of plan.appends) {
      const inserted = editor.appendMarkdown(append.fragment);
      for (const raw of append.spans) {
        const span = placeFragmentSpan(raw, append.fragment, inserted.from, editor.view.state.doc);
        if (span) placed.push(span);
      }
    }

    editor.view.dispatch(setProvenanceSpans(editor.view.state.tr, placed));

    // The document is byte-identical to what was stored, but the SPANS are new, so
    // the session is dirty on purpose: without a save the pending rows are never
    // cleared and the same work happens on every open.
    this.lastSavedSpans = '';
    this.documentChanged();
  }

  /**
   * Dissolving a span changes no text at all. Comparing markdown alone made such a
   * save return early, so a span the user dismissed came back on reload.
   */
  private spanFingerprint(): string {
    return JSON.stringify(provenanceSpans(this.options.editor.view.state).map(spanToJSON));
  }

  private isDirty(): boolean {
    return this.options.editor.getMarkdown() !== this.lastSaved
      || this.spanFingerprint() !== this.lastSavedSpans;
  }

  /**
   * Write now, and resolve when the write has actually happened — what the host
   * waits on before it closes a window or quits.
   */
  saveNow(): Promise<boolean> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.queue = this.queue.then(() => this.write(), () => this.write());
    // Whether the document is actually stored, which a caller about to close a
    // window or quit has to know: acknowledging a flush that did not save means
    // the host throws away the only copy.
    return this.queue.then(() => this.state !== 'error');
  }

  private async write(): Promise<void> {
    const { editor, streamId, transport } = this.options;

    // Read the document at the moment the write actually runs, never at the moment
    // it was queued: an append may have landed in between, and saving the older
    // snapshot against a newer revision would erase it.
    if (!this.isDirty()) {
      this.setState('saved');
      return;
    }

    const markdown = editor.getMarkdown();
    const baseRevision = this.revision;
    const spans = this.spansForSave();
    const fingerprint = this.spanFingerprint();
    const generation = this.generation;

    try {
      const { revision } = await transport.save({ streamId, markdown, baseRevision, spans: spans.map(spanToJSON) });

      /*
       * Something replaced or appended to the document while this was in flight, so
       * what came back describes a document that is gone. Adopting any of it would
       * both regress the revision and call unsaved work saved.
       *
       * The base revision is checked as well as the generation, and the answer has
       * to be exactly base + 1. A generation counter alone leaves a gap: a save can
       * win at revision 4 and have its reply delayed, an external append can take
       * revision 5, and the reload that follows arrives as a fresh document rather
       * than through a path that bumps the generation — and the stale reply is then
       * accepted. Requiring the base to still be current closes it.
       */
      if (generation !== this.generation || this.revision !== baseRevision) {
        this.setState(this.isDirty() ? 'saving' : 'saved');
        return;
      }
      if (!Number.isFinite(revision) || revision !== baseRevision + 1) {
        this.setState('error');
        transport.onError?.('The stream moved on while saving; the last change was not stored.', { revision, baseRevision });
        return;
      }

      this.revision = revision;
      this.lastSaved = markdown;
      this.lastSavedSpans = fingerprint;
      // Only settle if nothing changed while the write was in flight.
      this.setState(this.isDirty() ? 'saving' : 'saved');
    } catch (error) {
      if (generation !== this.generation) return; // the document moved on; not this save's problem
      this.setState('error');
      transport.onError?.('Changes could not be saved. Your edits are still in the editor.', error);
    }
  }

  /**
   * Spans as they stand in the document being saved. getMarkdown has already
   * settled the document, so these positions are the ones a reload will reproduce.
   */
  private spansForSave(): ProvenanceSpan[] {
    const { doc } = this.options.editor.view.state;
    return provenanceSpans(this.options.editor.view.state)
      .map((span) => ({ ...span, textHash: hashProvenanceText(doc, span) }));
  }

  /**
   * Something outside the editor wrote to this stream. The fragment is appended;
   * nothing already in the document is touched.
   */
  documentAppended(payload: {
    streamId: string;
    fragment: string;
    revision: number;
    /** Positions relative to the fragment, since the host cannot know PM ones. */
    spans?: ProvenanceSpanJSON[];
  }): void {
    if (payload.streamId !== this.options.streamId || !payload.fragment) return;

    // A gap means this editor missed an earlier append — it was not listening when
    // that one broadcast. Patching this fragment in and adopting the payload's
    // revision would make the next save pass the revision check and silently erase
    // the content that was missed. Reload instead.
    if (Number.isFinite(payload.revision) && payload.revision !== this.revision + 1) {
      this.options.transport.reload(this.options.streamId);
      return;
    }

    // Whether there is unsaved local work decides everything that follows.
    const wasDirty = this.isDirty();
    this.generation += 1;

    const inserted = this.options.editor.appendMarkdown(payload.fragment);
    this.revision = payload.revision;

    // Provenance for what was just appended. Dropping it — which is what happened
    // before — meant the next save replaced the whole stored set and erased it,
    // orphaning the AI exchange it pointed at.
    if (payload.spans?.length) {
      const { view } = this.options.editor;
      const placed = placeAppendedSpans(payload.spans, inserted)
        .filter((span) => hashProvenanceText(view.state.doc, span) === span.textHash);
      if (placed.length) view.dispatch(addProvenanceSpans(view.state.tr, placed));
    }

    if (wasDirty) {
      // The stored document has the fragment but NOT the local edits, so the merged
      // document is still unsaved. Recording it as saved — which is what this used
      // to do — made the editor report "saved" while the local edit existed only in
      // memory, and it was gone the next time the stream was opened.
      this.documentChanged();
      return;
    }

    // Nothing local was pending, so the stored document and this one now agree.
    this.lastSaved = this.options.editor.getMarkdown();
    this.lastSavedSpans = this.spanFingerprint();
    this.setState('saved');
  }

  /**
   * The save was rejected because the document had moved on. The host's copy wins —
   * it contains work this editor never saw.
   */
  documentConflict(payload: { streamId: string; markdown: string; revision: number; spans?: ProvenanceSpan[] }): void {
    if (payload.streamId !== this.options.streamId || typeof payload.markdown !== 'string') return;
    if (!Number.isFinite(payload.revision)) return;

    // Nothing local is pending, so the host copy is simply newer.
    if (!this.isDirty()) {
      this.adoptHostDocument(payload);
      return;
    }

    /*
     * There IS unsaved local work, and taking the host copy would delete it —
     * type a sentence, lose the revision race to a quick-panel capture, and the
     * sentence is gone. So the host copy is only merged when it can be PROVEN to
     * be this editor's last saved document plus something appended to the end,
     * which is what a conflict almost always is. Then the appended part is added
     * here too and the document stays dirty, so the local work is written next.
     */
    if (payload.markdown.startsWith(this.lastSaved)) {
      const appended = payload.markdown.slice(this.lastSaved.length);
      this.generation += 1;
      if (appended.trim()) this.options.editor.appendMarkdown(appended.replace(/^\n+/, '\n\n'));
      this.revision = payload.revision;
      this.documentChanged();
      return;
    }

    /*
     * The host copy is not an extension of what this editor last saved, so the two
     * genuinely diverged and nothing here can merge them safely. The local text is
     * kept and the revision is NOT adopted: saves keep failing, the error stays
     * visible, and nothing is lost. Better a save the user can see failing than a
     * paragraph that quietly disappears.
     *
     * ponytail: no merge UI. Add one if this fires in practice — it needs a real
     * divergence, which the append-only write path makes rare.
     */
    this.setState('error');
    this.options.transport.onError?.(
      'This stream changed elsewhere. Your edits are still here, but they cannot be saved until the conflict is resolved.',
      payload,
    );
  }

  /** Load a document from the host, as opening a stream or reloading does. */
  documentLoaded(payload: { markdown: string; revision: number; spans?: ProvenanceSpan[] }): void {
    this.adoptHostDocument(payload);
  }

  private adoptHostDocument(payload: { markdown: string; revision: number; spans?: ProvenanceSpan[] }): void {
    this.generation += 1;
    this.options.editor.setMarkdown(payload.markdown);
    this.revision = payload.revision;
    this.restoreSpans(payload.spans ?? []);
    this.lastSaved = this.options.editor.getMarkdown();
    this.lastSavedSpans = this.spanFingerprint();
    this.setState('saved');
  }

  /**
   * Keep only spans whose text still hashes to what was stored. A span that does
   * not is pointing at text that changed while this editor was not looking, and
   * showing it would claim the AI wrote something it did not.
   */
  private restoreSpans(spans: ProvenanceSpan[]): void {
    const { view } = this.options.editor;
    const valid = spans.filter((span) => hashProvenanceText(view.state.doc, span) === span.textHash);
    view.dispatch(setProvenanceSpans(view.state.tr, valid));
  }

  /**
   * Leaving the page. Whatever is pending is written FIRST — clearing the timer and
   * walking away means an edit made in the last 350ms is simply gone, which is what
   * clicking Back straight after typing used to do.
   *
   * The caller must let this settle before tearing the editor down, since the write
   * reads the document.
   */
  destroy(): Promise<boolean> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    return this.isDirty() ? this.saveNow() : Promise.resolve(true);
  }

  private setState(next: SaveState): void {
    if (this.state === next) return;
    this.state = next;
    this.options.transport.onSaveStateChange?.(next);
  }
}
