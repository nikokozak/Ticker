import type { RichTextEditor } from './editor';
import type { Node as ProseNode } from 'prosemirror-model';
import { parseMarkdown } from './markdown';
import { placeFragmentSpan, planReplay, type PendingAppend } from './pendingAppends';
import {
  addProvenanceSpans,
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
    docJSON: string;
    docFormatVersion: 1;
    markdown: string;
    baseRevision: number;
    spans: ProvenanceSpanJSON[];
    /**
     * The highest append revision whose provenance this editor has converted. The
     * store forgets only those rows; without it, it keeps every one — an editor
     * that does not understand pending appends must not be able to delete them.
     */
    resolvedPendingThrough?: number;
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
const DOCUMENT_FORMAT_VERSION = 1;

/** Enough for an edit that lands mid-write; a bound so a flush always answers. */
const MAX_FLUSH_PASSES = 5;

export class DocumentSession {
  private readonly options: Required<Pick<SessionOptions, 'autosaveDelay'>> & SessionOptions;

  private revision: number;

  private lastSavedDocument: string;

  /** Needed only while legacy pending rows still prove suffixes in markdown. */
  private lastSavedMarkdown: string;

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

  /**
   * The highest append revision whose provenance is safely in THIS document —
   * converted from its pending row, or never recorded one. It is what a save
   * reports, and the store forgets rows at or below it.
   *
   * `null` means this session has proven nothing and must never cause a row to be
   * forgotten. It only ever advances by an actual proof, and only contiguously: a
   * row that could not be converted stops it there for good, because the store
   * deletes everything at or below what it is told, so claiming a LATER revision
   * would take the unconverted row with it.
   */
  private pendingSafeThrough: number | null = null;

  constructor(options: SessionOptions) {
    this.options = { autosaveDelay: DEFAULT_AUTOSAVE_DELAY, ...options };
    this.revision = options.revision;
    this.lastSavedDocument = options.editor.getDocumentJSON();
    this.lastSavedMarkdown = options.editor.getMarkdownProjection();
    if (options.spans?.length) this.restoreSpans(options.spans);
    this.lastSavedSpans = this.spanFingerprint();
    this.adoptPendingAppends(options.pendingAppends ?? []);
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
   * Take on the pending rows for the document as it now stands — at open, and again
   * after any reload, since a reloaded document brings its own rows and a session
   * that ignored them could never let the store forget any of them again.
   */
  private adoptPendingAppends(pending: PendingAppend[]): void {
    this.pendingSafeThrough = null;
    if (!pending.length) {
      // No row was recorded at or below this revision, so nothing is lost by the
      // store forgetting that far. Saying so is what lets the row for a LIVE append
      // — one this session does convert, below — be forgotten in turn.
      this.pendingSafeThrough = this.revision;
      return;
    }
    this.convertPendingAppends(pending);
  }

  /**
   * Place the provenance of appends that happened while no editor was open.
   *
   * The converter already folded the rows into doc_json. Rebuild their claimed
   * document off-screen so a failed legacy proof cannot touch the user's live
   * document, selection, or undo history.
   *
   * Any proof that fails abandons the whole replay and leaves the rows alone. A
   * half-converted span points at the wrong text and claims the AI wrote something
   * it did not, which is worse than no highlighting; the rows survive, so a later
   * version can still convert them correctly.
   */
  private convertPendingAppends(pending: PendingAppend[]): void {
    const { editor } = this.options;
    const plan = planReplay(this.lastSavedMarkdown, this.revision, pending);
    if (!plan.ok) return this.abandonReplay(plan.reason);
    if (!plan.appends.length) return;

    const existing = provenanceSpans(editor.view.state);
    let replayed = parseMarkdown(plan.baseMarkdown);

    // Everything is placed before anything is committed. A partial conversion is
    // the worst outcome: the save that follows would delete the rows, so the spans
    // that could not be placed are gone permanently rather than merely deferred.
    const placed: ProvenanceSpan[] = [];
    for (const append of plan.appends) {
      const fragment = parseMarkdown(append.fragment);
      const insertedAt = replayed.content.size;
      replayed = replayed.copy(replayed.content.append(fragment.content));
      const converted = this.placeFragmentSpans(
        append.spans,
        append.fragment,
        insertedAt,
        [...existing, ...placed],
        replayed,
      );
      if (!converted) {
        return this.abandonReplay('spanUnplaceable');
      }
      placed.push(...converted);
    }

    if (!replayed.eq(editor.view.state.doc)) {
      // The rows describe a different tree, so their positions do not belong to
      // the canonical document even if their Markdown happens to look similar.
      return this.abandonReplay('replayDiverged');
    }

    editor.view.dispatch(setProvenanceSpans(editor.view.state.tr, [...existing, ...placed]));

    // Only now: every row and every span was converted, so the store may forget
    // them once this save lands.
    this.pendingSafeThrough = this.revision;
    // The document is byte-identical to what was stored but the SPANS are new, so
    // the session is dirty on purpose — without a save the rows are never cleared
    // and this happens again on every open.
    this.lastSavedSpans = '';
    this.documentChanged();
  }

  /**
   * Turn a fragment's raw spans into document ones — ALL of them or none.
   *
   * The same proof for a live append as for a replayed one, because the coordinates
   * are the same coordinates: the host records offsets into the fragment's own
   * markdown, which is all it can know without parsing the document. Treating them
   * as ProseMirror positions, which is what the live path used to do, lands the
   * highlight on whatever text happens to sit at that number.
   *
   * A span whose id is already here is skipped rather than doubled: a converted row
   * that was never cleared — because the save that would have cleared it did not
   * land — arrives a second time on the next open.
   */
  private placeFragmentSpans(
    raw: ProvenanceSpanJSON[],
    fragment: string,
    insertedAt: number,
    existing: ProvenanceSpan[],
    doc: ProseNode = this.options.editor.view.state.doc,
  ): ProvenanceSpan[] | null {
    const known = new Set(existing.map((span) => span.spanId));
    const placed: ProvenanceSpan[] = [];
    for (const one of raw) {
      if (known.has(one.spanId)) continue;
      const span = placeFragmentSpan(one, fragment, insertedAt, doc);
      if (!span) return null;
      placed.push(span);
    }
    return placed;
  }

  /** Leave the rows alone so a later version can still convert them correctly. */
  private abandonReplay(reason: string): void {
    this.pendingSafeThrough = null;
    this.options.transport.onError?.(
      'Some recent additions could not have their history restored; the text itself is intact.',
      reason,
    );
  }

  /**
   * Dissolving a span changes no text at all. Comparing markdown alone made such a
   * save return early, so a span the user dismissed came back on reload.
   */
  private spanFingerprint(): string {
    return JSON.stringify(provenanceSpans(this.options.editor.view.state).map(spanToJSON));
  }

  private isDirty(): boolean {
    return this.options.editor.getDocumentJSON() !== this.lastSavedDocument
      || this.spanFingerprint() !== this.lastSavedSpans;
  }

  /**
   * Write now, and resolve when the write has actually happened — what the host
   * waits on before it closes a window or quits.
   */
  saveNow(): Promise<boolean> {
    // Whether the document is actually stored, which a caller about to close a
    // window or quit has to know: acknowledging a flush that did not save means
    // the host throws away the only copy.
    const answer = this.queue.then(() => this.drain(), () => this.drain());
    // The queue stays a chain of settled voids, so one rejection cannot poison
    // every later save.
    this.queue = answer.then(() => {}, () => {});
    return answer;
  }

  /**
   * Write until there is nothing left to write.
   *
   * One pass is not enough. A write reads the document when it BEGINS, so anything
   * typed while it is in flight is not in it — and answering there reports a
   * document as stored while the last edit exists only in the editor. The host acts
   * on that answer by closing the window, which is exactly when the editor is the
   * only copy.
   */
  private async drain(): Promise<boolean> {
    for (let pass = 0; pass < MAX_FLUSH_PASSES; pass += 1) {
      // Anything the timer was going to write is written by this pass.
      if (this.timer) {
        clearTimeout(this.timer);
        this.timer = null;
      }
      await this.write();
      if (this.state === 'error') return false;
      if (!this.isDirty()) return true;
    }
    // Something is changing the document faster than it can be stored. Say so
    // rather than loop forever with a host waiting on the answer.
    return false;
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

    const docJSON = editor.getDocumentJSON();
    const markdown = editor.getMarkdownProjection();
    const baseRevision = this.revision;
    const spans = this.spansForSave();
    const fingerprint = this.spanFingerprint();
    const generation = this.generation;

    try {
      // Idempotent, so it is sent on every save rather than once: the store deletes
      // rows at or below it, and repeating a number whose rows are already gone
      // deletes nothing. Reporting it once instead meant a save that never landed
      // took the only chance to clear them with it.
      const resolvedPendingThrough = this.pendingSafeThrough ?? undefined;
      const { revision } = await transport.save({
        streamId,
        docJSON,
        docFormatVersion: DOCUMENT_FORMAT_VERSION,
        markdown,
        baseRevision,
        spans: spans.map(spanToJSON),
        resolvedPendingThrough,
      });

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
      this.lastSavedDocument = docJSON;
      this.lastSavedMarkdown = markdown;
      this.lastSavedSpans = fingerprint;
      // Only settle if nothing changed while the write was in flight.
      this.setState(this.isDirty() ? 'saving' : 'saved');
    } catch (error) {
      if (generation !== this.generation) return; // the document moved on; not this save's problem
      this.setState('error');
      transport.onError?.('Changes could not be saved. Your edits are still in the editor.', error);
    }
  }

  /** Spans as they stand in the canonical document being saved. */
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
    // Whether the rows were accounted for up to HERE, read before the revision
    // moves: only then can this append extend the claim without skipping a row.
    const contiguous = this.pendingSafeThrough === this.revision;
    this.generation += 1;

    const { view } = this.options.editor;
    const existing = provenanceSpans(view.state);
    const inserted = this.options.editor.appendMarkdown(payload.fragment);
    this.revision = payload.revision;

    // Provenance for what was just appended. Dropping it — which is what happened
    // before — meant the next save replaced the whole stored set and erased it,
    // orphaning the AI exchange it pointed at.
    //
    // The store also holds a row for this append. It may only be forgotten if EVERY
    // one of its spans was placed here, so a partial conversion leaves the row for
    // the next open to try again instead of clearing it half-done.
    const placed = this.placeFragmentSpans(payload.spans ?? [], payload.fragment, inserted.from, existing);
    if (placed?.length) view.dispatch(addProvenanceSpans(view.state.tr, placed));
    if (placed && contiguous) this.pendingSafeThrough = payload.revision;

    if (wasDirty) {
      // The stored document has the fragment but NOT the local edits, so the merged
      // document is still unsaved. Recording it as saved — which is what this used
      // to do — made the editor report "saved" while the local edit existed only in
      // memory, and it was gone the next time the stream was opened.
      this.documentChanged();
      return;
    }

    // The legacy append writer updated only the projection. Keep the old JSON
    // fingerprint dirty until this editor has restored the canonical document.
    this.lastSavedMarkdown = this.options.editor.getMarkdownProjection();

    // The spans just placed, though, are stored NOWHERE — an append writes its
    // provenance as a pending row, never as a span — and neither is the fact that
    // the row may now be forgotten. Either one means a save is owed.
    const owed = Boolean(placed?.length) || this.pendingSafeThrough === payload.revision;
    this.lastSavedSpans = owed ? '' : this.spanFingerprint();
    if (owed) this.documentChanged();
    else this.setState('saved');
  }

  /** The save was rejected because the stored document moved on. */
  documentConflict(payload: {
    streamId: string;
    docJSON?: string;
    docFormatVersion?: number;
    markdown: string;
    revision: number;
    spans?: ProvenanceSpan[];
    pendingAppends?: PendingAppend[];
  }): void {
    if (payload.streamId !== this.options.streamId || typeof payload.markdown !== 'string') return;
    if (!Number.isFinite(payload.revision)) return;

    // Nothing local is pending, so the host copy is simply newer.
    if (!this.isDirty()) {
      if (!this.adoptHostDocument(payload)) return;
      this.adoptPendingAppends(payload.pendingAppends ?? []);
      return;
    }

    // Only rows newer than this editor can explain the conflict. An older pending
    // row may still be waiting for provenance conversion, but replaying its text
    // here would duplicate content already present in lastSaved.
    const rows = [...(payload.pendingAppends ?? [])]
      .filter((append) => append.revision > this.revision)
      .sort((a, b) => a.revision - b.revision);
    if (rows[0]?.revision !== this.revision + 1) {
      this.refuseConflict(payload, 'revisionGap');
      return;
    }

    const plan = planReplay(payload.markdown, payload.revision, rows);
    if (!plan.ok) {
      this.refuseConflict(payload, plan.reason);
      return;
    }
    if (plan.baseMarkdown !== this.lastSavedMarkdown) {
      this.refuseConflict(payload, 'baseMismatch');
      return;
    }

    // Prove every raw span against its fragment BEFORE touching the live document.
    // A failed proof after the first append would need a rollback, which would
    // itself discard the user's selection and undo history.
    const proofs: ProvenanceSpan[][] = [];
    for (const append of plan.appends) {
      const fragment = parseMarkdown(append.fragment);
      const proven = append.spans.map((span) => placeFragmentSpan(span, append.fragment, 0, fragment));
      if (proven.some((span) => span === null)) {
        this.refuseConflict(payload, 'spanUnplaceable');
        return;
      }
      // Kept, so the live pass is arithmetic rather than a second proof. Proving it
      // twice and asserting the second one cannot fail meant that if it ever did,
      // it threw AFTER the first fragment had already been appended — a
      // half-merged document, and an exception out of a bridge message.
      proofs.push(proven as ProvenanceSpan[]);
    }

    const pendingWasContiguous = this.pendingSafeThrough === this.revision;
    const { editor } = this.options;
    const { view } = editor;
    const placed: ProvenanceSpan[] = [];
    this.generation += 1;

    plan.appends.forEach((append, index) => {
      const inserted = editor.appendMarkdown(append.fragment);
      // appendMarkdown puts that same parsed tree in whole, at inserted.from, so a
      // position measured inside the fragment is that base plus the position.
      placed.push(...proofs[index].map((span) => ({
        ...span,
        from: span.from + inserted.from,
        to: span.to + inserted.from,
      })));
    });
    if (placed.length) view.dispatch(addProvenanceSpans(view.state.tr, placed));

    this.revision = payload.revision;
    if (pendingWasContiguous) this.pendingSafeThrough = payload.revision;
    // The saved fingerprints deliberately stay put: they do not include the local edit or the
    // newly merged fragments, so the whole live document is still owed a save.
    this.documentChanged();
  }

  private refuseConflict(payload: unknown, reason: string): void {
    this.setState('error');
    this.options.transport.onError?.(
      'This stream changed elsewhere. Your edits are still here, but they cannot be saved until the conflict is resolved.',
      { reason, payload },
    );
  }

  /**
   * Load a document from the host, as reloading after an unreconcilable gap does.
   *
   * The rows come with it. A reload replaces the document this session had proven
   * things about, so without them it could never let the store forget another row —
   * and rows that outlive the revision they were recorded at can never be replayed,
   * since replaying means peeling them off the END of the stored markdown.
   */
  documentLoaded(payload: {
    docJSON?: string;
    docFormatVersion?: number;
    markdown: string;
    revision: number;
    spans?: ProvenanceSpan[];
    pendingAppends?: PendingAppend[];
  }): void {
    if (!this.adoptHostDocument(payload)) return;
    this.adoptPendingAppends(payload.pendingAppends ?? []);
  }

  private adoptHostDocument(payload: {
    docJSON?: string;
    docFormatVersion?: number;
    markdown: string;
    revision: number;
    spans?: ProvenanceSpan[];
  }): boolean {
    if (payload.docFormatVersion !== DOCUMENT_FORMAT_VERSION || typeof payload.docJSON !== 'string') {
      this.refuseHostDocument('missingCanonicalDocument');
      return false;
    }

    try {
      this.options.editor.setDocumentJSON(payload.docJSON);
    } catch (error) {
      this.refuseHostDocument('invalidCanonicalDocument', error);
      return false;
    }

    this.generation += 1;
    this.revision = payload.revision;
    this.restoreSpans(payload.spans ?? []);
    this.lastSavedDocument = this.options.editor.getDocumentJSON();
    this.lastSavedMarkdown = payload.markdown;
    this.lastSavedSpans = this.spanFingerprint();
    // The document it had proven things about is gone; a caller that knows the new
    // document's rows says so by calling adoptPendingAppends after this.
    this.pendingSafeThrough = null;
    this.setState('saved');
    return true;
  }

  private refuseHostDocument(reason: string, detail?: unknown): void {
    this.setState('error');
    this.options.transport.onError?.(
      'This stream has no readable rich-text document. Your current text was left untouched.',
      { reason, detail },
    );
  }

  /**
   * Keep only spans whose text still hashes to what was stored. A span that does
   * not is pointing at text that changed while this editor was not looking, and
   * showing it would claim the AI wrote something it did not.
   */
  private restoreSpans(spans: ProvenanceSpan[]): void {
    const { view } = this.options.editor;
    const valid = spans.filter((span) => (
      span.from >= 0
      && span.to <= view.state.doc.content.size
      && span.from < span.to
      && hashProvenanceText(view.state.doc, span) === span.textHash
    ));
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
