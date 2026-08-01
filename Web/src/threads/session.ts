import type { StreamThreadJSON } from '../types/models';

export type ThreadSaveState = 'saved' | 'saving' | 'error' | 'conflict';

export interface ThreadDraft {
  title: string;
}

interface ThreadDraftSessionOptions {
  thread: StreamThreadJSON;
  save: (input: {
    streamId: string;
    threadId: string;
    title: string;
    baseRevision: number;
  }) => Promise<{ conflict: boolean; thread: StreamThreadJSON }>;
  autosaveDelay?: number;
  onSaveStateChange?: (state: ThreadSaveState) => void;
}

const DEFAULT_AUTOSAVE_DELAY = 600;
const MAX_FLUSH_PASSES = 5;

/** Revision-checked ownership of editable thread metadata. */
export class ThreadDraftSession {
  private readonly options: Required<Pick<ThreadDraftSessionOptions, 'autosaveDelay'>>
    & ThreadDraftSessionOptions;

  private revision: number;

  private saved: ThreadDraft;

  private draft: ThreadDraft;

  private timer: ReturnType<typeof setTimeout> | null = null;

  private queue: Promise<void> = Promise.resolve();

  private state: ThreadSaveState = 'saved';

  private storedConflict: StreamThreadJSON | null = null;

  constructor(options: ThreadDraftSessionOptions) {
    this.options = { autosaveDelay: DEFAULT_AUTOSAVE_DELAY, ...options };
    this.revision = options.thread.revision;
    this.saved = {
      title: options.thread.title,
    };
    this.draft = { ...this.saved };
  }

  get saveState(): ThreadSaveState {
    return this.state;
  }

  update(draft: ThreadDraft): void {
    this.draft = { ...this.draft, ...draft };
    if (this.storedConflict) return;
    this.setState('saving');
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.saveNow();
    }, this.options.autosaveDelay);
  }

  saveNow(): Promise<boolean> {
    const answer = this.queue.then(() => this.drain(), () => this.drain());
    this.queue = answer.then(() => {}, () => {});
    return answer;
  }

  /** Keep local work until the user explicitly chooses the stored copy. */
  reloadStored(): StreamThreadJSON | null {
    const thread = this.storedConflict;
    if (!thread) return null;
    this.revision = thread.revision;
    this.saved = {
      title: thread.title,
    };
    this.draft = { ...this.saved };
    this.storedConflict = null;
    this.setState('saved');
    return thread;
  }

  /** Explicitly overwrite the stored draft after showing both versions to the user. */
  keepLocal(): Promise<boolean> {
    const thread = this.storedConflict;
    if (!thread) return Promise.resolve(true);
    this.revision = thread.revision;
    this.saved = {
      title: thread.title,
    };
    this.storedConflict = null;
    this.setState('saving');
    return this.saveNow();
  }

  discard(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private isDirty(): boolean {
    return this.draft.title !== this.saved.title;
  }

  private async drain(): Promise<boolean> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (this.storedConflict) return false;

    for (let pass = 0; pass < MAX_FLUSH_PASSES; pass += 1) {
      await this.write();
      if (this.state === 'error' || this.state === 'conflict') return false;
      if (!this.isDirty()) return true;
    }
    this.setState('error');
    return false;
  }

  private async write(): Promise<void> {
    if (!this.isDirty()) {
      this.setState('saved');
      return;
    }

    const snapshot = { ...this.draft };
    const baseRevision = this.revision;
    try {
      const result = await this.options.save({
        streamId: this.options.thread.streamId,
        threadId: this.options.thread.threadId,
        ...snapshot,
        baseRevision,
      });
      if (result.thread.threadId !== this.options.thread.threadId
          || result.thread.streamId !== this.options.thread.streamId) {
        this.setState('error');
        return;
      }
      if (result.conflict) {
        this.storedConflict = result.thread;
        this.setState('conflict');
        return;
      }
      if (result.thread.revision !== baseRevision + 1) {
        this.setState('error');
        return;
      }

      this.revision = result.thread.revision;
      this.saved = snapshot;
      this.setState(this.isDirty() ? 'saving' : 'saved');
    } catch {
      this.setState('error');
    }
  }

  private setState(next: ThreadSaveState): void {
    if (next === this.state) return;
    this.state = next;
    this.options.onSaveStateChange?.(next);
  }
}
