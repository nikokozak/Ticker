import type { RichTextEditor } from './editor';
import {
  hashProvenanceText,
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

  constructor(options: SessionOptions) {
    this.options = { autosaveDelay: DEFAULT_AUTOSAVE_DELAY, ...options };
    this.revision = options.revision;
    this.lastSaved = options.editor.getMarkdown();
    if (options.spans?.length) this.restoreSpans(options.spans);
    this.lastSavedSpans = this.spanFingerprint();
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
  saveNow(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.queue = this.queue.then(() => this.write(), () => this.write());
    return this.queue;
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

    try {
      const { revision } = await transport.save({ streamId, markdown, baseRevision, spans: spans.map(spanToJSON) });
      if (Number.isFinite(revision)) this.revision = revision;
      this.lastSaved = markdown;
      this.lastSavedSpans = fingerprint;
      // Only settle if nothing changed while the write was in flight.
      this.setState(this.isDirty() ? 'saving' : 'saved');
    } catch (error) {
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
  documentAppended(payload: { streamId: string; fragment: string; revision: number }): void {
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

    this.options.editor.appendMarkdown(payload.fragment);
    this.revision = payload.revision;

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

    this.adoptHostDocument(payload);
  }

  /** Load a document from the host, as opening a stream or reloading does. */
  documentLoaded(payload: { markdown: string; revision: number; spans?: ProvenanceSpan[] }): void {
    this.adoptHostDocument(payload);
  }

  private adoptHostDocument(payload: { markdown: string; revision: number; spans?: ProvenanceSpan[] }): void {
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
  destroy(): Promise<void> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    return this.isDirty() ? this.saveNow() : Promise.resolve();
  }

  private setState(next: SaveState): void {
    if (this.state === next) return;
    this.state = next;
    this.options.transport.onSaveStateChange?.(next);
  }
}
