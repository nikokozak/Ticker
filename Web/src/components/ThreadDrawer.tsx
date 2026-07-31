import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react';
import {
  listStreamThreads,
  loadStreamThread,
  saveStreamThread,
} from '../types/bridge';
import type { StreamThreadJSON } from '../types/models';
import { ThreadDraftSession, type ThreadSaveState } from '../threads/session';
import { useToastStore } from '../store/toastStore';
import { XIcon } from './icons';

export interface ThreadDrawerHandle {
  flush: () => Promise<boolean>;
  close: () => Promise<boolean>;
  openThread: (threadId: string) => Promise<boolean>;
  showThread: (thread: StreamThreadJSON) => Promise<boolean>;
}

interface ThreadDrawerProps {
  streamId: string;
  isOpen: boolean;
  onRequestClose: () => void;
  onAfterClose?: () => void;
}

const SAVE_LABEL: Record<ThreadSaveState, string> = {
  saved: 'Saved',
  saving: 'Saving…',
  error: 'Save failed',
  conflict: 'Needs attention',
};

function displayTitle(thread: StreamThreadJSON): string {
  return thread.title.trim() || 'Untitled thread';
}

function sourceLabel(thread: StreamThreadJSON): string | null {
  const source = thread.sourceShortTitle || thread.sourceName;
  if (!source) return null;
  return thread.sourcePage ? `${source} · page ${thread.sourcePage}` : source;
}

export const ThreadDrawer = forwardRef<ThreadDrawerHandle, ThreadDrawerProps>(function ThreadDrawer({
  streamId,
  isOpen,
  onRequestClose,
  onAfterClose,
}, ref) {
  const sessionRef = useRef<ThreadDraftSession | null>(null);
  const [threads, setThreads] = useState<StreamThreadJSON[]>([]);
  const [activeThread, setActiveThread] = useState<StreamThreadJSON | null>(null);
  const [title, setTitle] = useState('');
  const [workingText, setWorkingText] = useState('');
  const [saveState, setSaveState] = useState<ThreadSaveState>('saved');
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const addToast = useToastStore((state) => state.addToast);

  const installThread = useCallback((thread: StreamThreadJSON) => {
    sessionRef.current?.discard();
    setActiveThread(thread);
    setTitle(thread.title);
    setWorkingText(thread.workingText);
    setSaveState('saved');
    sessionRef.current = new ThreadDraftSession({
      thread,
      save: saveStreamThread,
      onSaveStateChange: setSaveState,
    });
  }, []);

  const refreshList = useCallback(async () => {
    setLoading(true);
    setLoadError(false);
    try {
      const result = await listStreamThreads(streamId);
      setThreads(result.threads);
    } catch {
      setLoadError(true);
    } finally {
      setLoading(false);
    }
  }, [streamId]);

  const flush = useCallback(() => sessionRef.current?.saveNow() ?? Promise.resolve(true), []);

  const close = useCallback(async () => {
    if (!await flush()) {
      addToast('Your thread note could not be saved, so the drawer stayed open.', 'error');
      return false;
    }
    sessionRef.current?.discard();
    sessionRef.current = null;
    setActiveThread(null);
    setSaveState('saved');
    onRequestClose();
    window.setTimeout(() => onAfterClose?.(), 0);
    return true;
  }, [addToast, flush, onAfterClose, onRequestClose]);

  const openThread = useCallback(async (threadId: string) => {
    if (activeThread?.threadId === threadId) return true;
    if (!await flush()) return false;
    setLoading(true);
    setLoadError(false);
    try {
      const result = await loadStreamThread(streamId, threadId);
      installThread(result.thread);
      return true;
    } catch {
      addToast('This thread could not be opened.', 'error');
      return false;
    } finally {
      setLoading(false);
    }
  }, [activeThread?.threadId, addToast, flush, installThread, streamId]);

  const showThread = useCallback(async (thread: StreamThreadJSON) => {
    if (activeThread?.threadId === thread.threadId) return true;
    if (!await flush()) return false;
    installThread(thread);
    return true;
  }, [activeThread?.threadId, flush, installThread]);

  useImperativeHandle(ref, () => ({
    flush,
    close,
    openThread,
    showThread,
  }), [close, flush, openThread, showThread]);

  useEffect(() => {
    if (isOpen && !activeThread) void refreshList();
  }, [activeThread, isOpen, refreshList]);

  useEffect(() => () => sessionRef.current?.discard(), []);

  const updateDraft = (nextTitle: string, nextWorkingText: string) => {
    setTitle(nextTitle);
    setWorkingText(nextWorkingText);
    sessionRef.current?.update({ title: nextTitle, workingText: nextWorkingText });
  };

  const showList = async () => {
    if (!await flush()) return;
    sessionRef.current?.discard();
    sessionRef.current = null;
    setActiveThread(null);
    setSaveState('saved');
    await refreshList();
  };

  const reloadStored = () => {
    const stored = sessionRef.current?.reloadStored();
    if (!stored) return;
    setActiveThread(stored);
    setTitle(stored.title);
    setWorkingText(stored.workingText);
  };

  const keepLocal = async () => {
    if (!await sessionRef.current?.keepLocal()) return;
    addToast('Your local note was saved.', 'success');
  };

  if (!isOpen) return null;

  return (
    <aside
      className="thread-drawer"
      aria-label="Threads"
      onKeyDown={(event) => {
        if (event.key !== 'Escape') return;
        event.preventDefault();
        event.stopPropagation();
        void close();
      }}
    >
      <header className="thread-drawer-header">
        {activeThread ? (
          <button type="button" className="thread-drawer-back" onClick={() => { void showList(); }}>
            ← Threads
          </button>
        ) : (
          <h2>Threads</h2>
        )}
        <button
          type="button"
          className="thread-drawer-close"
          aria-label="Close threads"
          onClick={() => { void close(); }}
        >
          <XIcon size={14} />
        </button>
      </header>

      {activeThread ? (
        <div className="thread-detail">
          <label className="thread-title-label">
            <span>Title</span>
            <input
              className="thread-title-input"
              aria-label="Thread title"
              value={title}
              placeholder="Untitled thread"
              onChange={(event) => updateDraft(event.target.value, workingText)}
            />
          </label>

          <section className="thread-origin" aria-labelledby="thread-origin-heading">
            <h3 id="thread-origin-heading">Started from</h3>
            <blockquote>{activeThread.anchorText || 'No starting passage.'}</blockquote>
            {sourceLabel(activeThread) && <p>{sourceLabel(activeThread)}</p>}
          </section>

          <section className="thread-note" aria-labelledby="thread-note-heading">
            <div className="thread-note-heading-row">
              <h3 id="thread-note-heading">My note</h3>
              <span className={`thread-save-state thread-save-state--${saveState}`} role="status">
                {SAVE_LABEL[saveState]}
              </span>
            </div>
            <textarea
              aria-label="My note"
              value={workingText}
              placeholder="Write what you think, what is missing, or what to check next…"
              onChange={(event) => updateDraft(title, event.target.value)}
            />
            {saveState === 'conflict' && (
              <div className="thread-save-warning" role="alert">
                <p>This note changed elsewhere. Your local note is still here.</p>
                <button type="button" onClick={() => { void keepLocal(); }}>Save my note instead</button>
                <button type="button" onClick={reloadStored}>Reload stored note</button>
              </div>
            )}
            {saveState === 'error' && (
              <div className="thread-save-warning" role="alert">
                <p>Your note is still here, but it could not be saved.</p>
                <button type="button" onClick={() => { void flush(); }}>Retry save</button>
              </div>
            )}
          </section>
        </div>
      ) : (
        <div className="thread-list">
          {loading && <p className="thread-list-state" role="status">Loading threads…</p>}
          {!loading && loadError && (
            <div className="thread-list-state" role="alert">
              <p>Threads could not be loaded.</p>
              <button type="button" onClick={() => { void refreshList(); }}>Try again</button>
            </div>
          )}
          {!loading && !loadError && threads.length === 0 && (
            <p className="thread-list-state">No threads yet. Select text in the Stream to start one.</p>
          )}
          {!loading && !loadError && threads.map((thread) => (
            <button
              key={thread.threadId}
              type="button"
              className="thread-list-item"
              onClick={() => { void openThread(thread.threadId); }}
            >
              <strong>{displayTitle(thread)}</strong>
              <span className="thread-list-anchor">{thread.anchorText || 'No starting passage'}</span>
              {sourceLabel(thread) && <span className="thread-list-source">{sourceLabel(thread)}</span>}
              <time dateTime={thread.updatedAt}>{new Date(thread.updatedAt).toLocaleString()}</time>
            </button>
          ))}
        </div>
      )}
    </aside>
  );
});
