import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from 'react';
import MarkdownIt from 'markdown-it';
import {
  bridge,
  listStreamThreads,
  loadStreamThread,
  saveStreamThread,
} from '../types/bridge';
import type { AIExchangeJSON, SourceScope, StreamThreadJSON } from '../types/models';
import { ThreadDraftSession, type ThreadSaveState } from '../threads/session';
import {
  manifestCitations,
  parseThreadAISentFacts,
  type ThreadAISentFacts,
} from '../threads/context';
import { useToastStore } from '../store/toastStore';
import { buildCitationURL, swapCitationMarkers } from '../utils/citationMarkers';
import { XIcon } from './icons';

export interface ThreadDrawerHandle {
  flush: () => Promise<boolean>;
  cancelAI: () => void;
  close: () => Promise<boolean>;
  openThread: (threadId: string) => Promise<boolean>;
  showThread: (thread: StreamThreadJSON) => Promise<boolean>;
}

export interface ThreadInsertionRequest {
  kind: 'note' | 'ai';
  text: string;
  threadId: string;
}

interface ThreadDrawerProps {
  streamId: string;
  isOpen: boolean;
  onRequestClose: () => void;
  onAfterClose?: () => void;
  onLocateAnchor?: (thread: StreamThreadJSON) => boolean;
  sourceScope?: SourceScope;
  onBeginAI?: () => boolean;
  onEndAI?: () => void;
  onOpenPDFDestination?: (url: string) => void;
  onRequestInsertion?: (request: ThreadInsertionRequest) => void;
  streamSaveErrorThreadId?: string | null;
  onRetryStreamSave?: () => void;
}

interface PendingThreadAI {
  requestId: string;
  prompt: string;
  response: string;
  sentContext?: ThreadAISentFacts;
  error?: string;
}

const threadMarkdown = MarkdownIt('commonmark', {
  html: false,
  breaks: false,
  linkify: false,
  typographer: false,
});
threadMarkdown.renderer.rules.image = (tokens, index) => (
  threadMarkdown.utils.escapeHtml(tokens[index].content || 'Image')
);

const SAVE_LABEL: Record<ThreadSaveState, string> = {
  saved: 'Saved',
  saving: 'Saving…',
  error: 'Save failed',
  conflict: 'Needs attention',
};

function displayTitle(thread: StreamThreadJSON): string {
  return thread.title.trim() || 'Untitled thread';
}

function relativeTime(value: string, now = Date.now()): string {
  const seconds = Math.round((Date.parse(value) - now) / 1_000);
  if (!Number.isFinite(seconds)) return 'Unknown time';
  const formatter = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const absolute = Math.abs(seconds);
  if (absolute < 60) return formatter.format(seconds, 'second');
  if (absolute < 3_600) return formatter.format(Math.round(seconds / 60), 'minute');
  if (absolute < 86_400) return formatter.format(Math.round(seconds / 3_600), 'hour');
  if (absolute < 2_592_000) return formatter.format(Math.round(seconds / 86_400), 'day');
  if (absolute < 31_536_000) return formatter.format(Math.round(seconds / 2_592_000), 'month');
  return formatter.format(Math.round(seconds / 31_536_000), 'year');
}

function sourceLabel(thread: StreamThreadJSON): string | null {
  const source = thread.sourceShortTitle || thread.sourceName;
  if (!source) return null;
  return thread.sourcePage ? `${source} · page ${thread.sourcePage}` : source;
}

function threadSourceURL(thread: StreamThreadJSON): string | null {
  if (!thread.sourceId) return null;
  const params = new URLSearchParams();
  if (thread.highlightId) params.set('highlight', thread.highlightId);
  if (thread.sourcePage) params.set('page', String(thread.sourcePage));
  const query = params.toString();
  return `ticker-pdf://${thread.sourceId}${query ? `?${query}` : '?page=1'}`;
}

function sourceURL(source: ThreadAISentFacts['sources'][number]): string {
  if (source.page && source.chunkId) {
    return buildCitationURL({
      sourceId: source.sourceId,
      chunkId: source.chunkId,
      page: source.page,
    });
  }
  return `ticker-pdf://${source.sourceId}?page=1`;
}

function renderedExchangeMarkdown(exchange: AIExchangeJSON): string {
  return swapCitationMarkers(exchange.responseRaw, manifestCitations(exchange.sourceManifest));
}

function SentContext({
  facts,
  onOpenPDFDestination,
}: {
  facts: ThreadAISentFacts;
  onOpenPDFDestination?: (url: string) => void;
}) {
  const included = facts.turns.includedRequestIds.length;
  return (
    <details className="thread-sent-context">
      <summary>What the AI used</summary>
      <div>
        <h4>Started from</h4>
        <blockquote>{facts.anchor.text || 'No starting passage.'}</blockquote>
        <h4>My note</h4>
        {facts.note.sent ? <p>{facts.note.text}</p> : <p>Not sent (empty).</p>}
        {facts.turns.totalAtSend > 0 && (
          <p>Previous turns: {included} of {facts.turns.totalAtSend}</p>
        )}
        <h4>Sources</h4>
        {facts.sources.length > 0 ? (
          <div className="thread-sent-sources">
            {facts.sources.map((source) => (
              <button
                key={`${source.sourceId}:${source.chunkId ?? 'whole'}:${source.page ?? 0}`}
                type="button"
                onClick={() => onOpenPDFDestination?.(sourceURL(source))}
              >
                {source.shortTitle}{source.page ? ` · page ${source.page}` : ' · whole source'}
              </button>
            ))}
          </div>
        ) : (
          <p>{facts.sourceContextMode === 'unavailable'
            ? 'Source retrieval was unavailable.'
            : 'No source passage was sent.'}</p>
        )}
      </div>
    </details>
  );
}

function AIResponse({
  markdown,
  sourceManifest,
  onOpenPDFDestination,
}: {
  markdown: string;
  sourceManifest: string;
  onOpenPDFDestination?: (url: string) => void;
}) {
  const html = useMemo(() => {
    return threadMarkdown.render(swapCitationMarkers(markdown, manifestCitations(sourceManifest)));
  }, [markdown, sourceManifest]);

  return (
    <div
      className="thread-ai-response"
      onClick={(event) => {
        const link = (event.target as HTMLElement).closest('a');
        if (!link) return;
        event.preventDefault();
        const href = link.getAttribute('href') ?? '';
        if (href.startsWith('ticker-pdf://')) {
          onOpenPDFDestination?.(href);
        } else if (/^https?:\/\//i.test(href)) {
          bridge.send({ type: 'openExternalURL', payload: { url: href } });
        }
      }}
      // markdown-it runs with HTML and images disabled above.
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

function ThreadExchange({
  exchange,
  onOpenPDFDestination,
  onAddToStream,
}: {
  exchange: AIExchangeJSON;
  onOpenPDFDestination?: (url: string) => void;
  onAddToStream?: (text: string) => void;
}) {
  const facts = parseThreadAISentFacts(exchange.sourceManifest);
  return (
    <article className="thread-exchange">
      <div className="thread-user-turn">
        <span>You</span>
        <p>{exchange.userInput}</p>
      </div>
      <div className="thread-assistant-turn">
        <span>AI</span>
        <AIResponse
          markdown={exchange.responseRaw}
          sourceManifest={exchange.sourceManifest}
          onOpenPDFDestination={onOpenPDFDestination}
        />
        {onAddToStream && (
          <button
            type="button"
            className="thread-add-to-stream"
            onClick={() => onAddToStream(renderedExchangeMarkdown(exchange))}
          >
            Place in Stream…
          </button>
        )}
      </div>
      {facts && <SentContext facts={facts} onOpenPDFDestination={onOpenPDFDestination} />}
    </article>
  );
}

export const ThreadDrawer = forwardRef<ThreadDrawerHandle, ThreadDrawerProps>(function ThreadDrawer({
  streamId,
  isOpen,
  onRequestClose,
  onAfterClose,
  onLocateAnchor,
  sourceScope = 'auto',
  onBeginAI,
  onEndAI,
  onOpenPDFDestination,
  onRequestInsertion,
  streamSaveErrorThreadId,
  onRetryStreamSave,
}, ref) {
  const sessionRef = useRef<ThreadDraftSession | null>(null);
  const aiStartGenerationRef = useRef(0);
  const activeRequestIdRef = useRef<string | null>(null);
  const activePromptRef = useRef<string | null>(null);
  const aiClaimedRef = useRef(false);
  const [threads, setThreads] = useState<StreamThreadJSON[]>([]);
  const [activeThread, setActiveThread] = useState<StreamThreadJSON | null>(null);
  const [title, setTitle] = useState('');
  const [workingText, setWorkingText] = useState('');
  const [exchanges, setExchanges] = useState<AIExchangeJSON[]>([]);
  const [prompt, setPrompt] = useState('');
  const [pendingAI, setPendingAI] = useState<PendingThreadAI | null>(null);
  const [preparingAI, setPreparingAI] = useState(false);
  const [saveState, setSaveState] = useState<ThreadSaveState>('saved');
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [anchorChanged, setAnchorChanged] = useState(false);
  const addToast = useToastStore((state) => state.addToast);

  const installThread = useCallback((thread: StreamThreadJSON) => {
    sessionRef.current?.discard();
    setActiveThread(thread);
    setTitle(thread.title);
    setWorkingText(thread.workingText);
    setExchanges(thread.exchanges ?? []);
    setPrompt('');
    setPendingAI(null);
    activePromptRef.current = null;
    setSaveState('saved');
    setAnchorChanged(Boolean(thread.anchorSpanId && onLocateAnchor && !onLocateAnchor(thread)));
    sessionRef.current = new ThreadDraftSession({
      thread,
      save: saveStreamThread,
      onSaveStateChange: setSaveState,
    });
  }, [onLocateAnchor]);

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

  const releaseAI = useCallback(() => {
    if (!aiClaimedRef.current) return;
    aiClaimedRef.current = false;
    onEndAI?.();
  }, [onEndAI]);

  const cancelAI = useCallback(() => {
    aiStartGenerationRef.current += 1;
    const requestId = activeRequestIdRef.current;
    activeRequestIdRef.current = null;
    const activePrompt = activePromptRef.current;
    activePromptRef.current = null;
    if (requestId) bridge.send({ type: 'cancelDocumentAI', payload: { requestId } });
    if (activePrompt) setPrompt(activePrompt);
    setPreparingAI(false);
    setPendingAI(null);
    releaseAI();
  }, [releaseAI]);

  const close = useCallback(async () => {
    cancelAI();
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
  }, [addToast, cancelAI, flush, onAfterClose, onRequestClose]);

  const openThread = useCallback(async (threadId: string) => {
    if (activeThread?.threadId === threadId) return true;
    cancelAI();
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
  }, [activeThread?.threadId, addToast, cancelAI, flush, installThread, streamId]);

  const showThread = useCallback(async (thread: StreamThreadJSON) => {
    if (activeThread?.threadId === thread.threadId) return true;
    cancelAI();
    if (!await flush()) return false;
    installThread(thread);
    return true;
  }, [activeThread?.threadId, cancelAI, flush, installThread]);

  useImperativeHandle(ref, () => ({
    flush,
    cancelAI,
    close,
    openThread,
    showThread,
  }), [cancelAI, close, flush, openThread, showThread]);

  useEffect(() => {
    if (isOpen && !activeThread) void refreshList();
  }, [activeThread, isOpen, refreshList]);

  useEffect(() => () => {
    sessionRef.current?.discard();
    aiStartGenerationRef.current += 1;
    const requestId = activeRequestIdRef.current;
    if (requestId) bridge.send({ type: 'cancelDocumentAI', payload: { requestId } });
    if (aiClaimedRef.current) onEndAI?.();
  }, [onEndAI]);

  useEffect(() => bridge.onMessage((message) => {
    const payload = message.payload as Record<string, unknown> | undefined;
    const requestId = activeRequestIdRef.current;
    if (!requestId || payload?.requestId !== requestId) return;

    if (message.type === 'threadAIContext') {
      const sentContext = parseThreadAISentFacts(payload.sentContext);
      if (sentContext) setPendingAI((pending) => (
        pending?.requestId === requestId ? { ...pending, sentContext } : pending
      ));
      return;
    }
    if (message.type === 'documentAIChunk' && typeof payload.chunk === 'string') {
      setPendingAI((pending) => (
        pending?.requestId === requestId
          ? { ...pending, response: pending.response + (payload.chunk as string) }
          : pending
      ));
      return;
    }
    if (message.type === 'documentAIComplete') {
      const exchange = payload.exchange as AIExchangeJSON | undefined;
      activeRequestIdRef.current = null;
      releaseAI();
      if (!exchange || exchange.requestId !== requestId || exchange.threadId !== activeThread?.threadId) {
        setPendingAI((pending) => pending && {
          ...pending,
          error: 'The reply finished, but its saved receipt was invalid.',
        });
        return;
      }
      activePromptRef.current = null;
      setExchanges((current) => current.some((item) => item.requestId === exchange.requestId)
        ? current
        : [...current, exchange]);
      setPendingAI(null);
      return;
    }
    if (message.type === 'documentAIError') {
      activeRequestIdRef.current = null;
      releaseAI();
      const error = typeof payload.error === 'string' ? payload.error : 'AI request failed.';
      setPendingAI((pending) => pending && { ...pending, error });
    }
  }), [activeThread?.threadId, releaseAI]);

  const updateDraft = (nextTitle: string, nextWorkingText: string) => {
    setTitle(nextTitle);
    setWorkingText(nextWorkingText);
    sessionRef.current?.update({ title: nextTitle, workingText: nextWorkingText });
  };

  const showList = async () => {
    cancelAI();
    if (!await flush()) return;
    sessionRef.current?.discard();
    sessionRef.current = null;
    setActiveThread(null);
    setSaveState('saved');
    await refreshList();
  };

  const sendPrompt = async () => {
    const thread = activeThread;
    const query = prompt.trim();
    if (!thread || !query || pendingAI || preparingAI) return;
    if (saveState !== 'saved') {
      addToast('Wait until your note is saved before sending.', 'info');
      return;
    }
    if (onBeginAI && !onBeginAI()) return;

    aiClaimedRef.current = true;
    const generation = ++aiStartGenerationRef.current;
    setPreparingAI(true);
    if (!await flush()) {
      if (generation === aiStartGenerationRef.current) {
        setPreparingAI(false);
        releaseAI();
        addToast('Your note must be saved before it can be sent.', 'error');
      }
      return;
    }
    if (generation !== aiStartGenerationRef.current || activeThread?.threadId !== thread.threadId) return;

    const requestId = crypto.randomUUID();
    activeRequestIdRef.current = requestId;
    activePromptRef.current = query;
    setPendingAI({ requestId, prompt: query, response: '' });
    setPrompt('');
    setPreparingAI(false);
    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId,
        threadId: thread.threadId,
        query,
        sourceScope,
        imageURLs: [],
      },
    });
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

  const requestInsertion = async (kind: ThreadInsertionRequest['kind'], text: string) => {
    const thread = activeThread;
    if (!thread || !text.trim() || !onRequestInsertion || activeRequestIdRef.current || preparingAI) return;
    if (!await flush()) {
      addToast('Save the thread before adding from it.', 'error');
      return;
    }
    onRequestInsertion({ kind, text, threadId: thread.threadId });
  };

  const insertionBlocked = preparingAI || Boolean(pendingAI && !pendingAI.error);

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

          {streamSaveErrorThreadId === activeThread.threadId && (
            <div className="thread-stream-save-warning" role="alert">
              <p>Added text is not saved.</p>
              <button type="button" onClick={onRetryStreamSave}>Retry Save</button>
            </div>
          )}

          <section className="thread-origin" aria-labelledby="thread-origin-heading">
            <h3 id="thread-origin-heading">Started from</h3>
            <blockquote>{activeThread.anchorText || 'No starting passage.'}</blockquote>
            {sourceLabel(activeThread) && (
              onOpenPDFDestination && threadSourceURL(activeThread) ? (
                <button
                  type="button"
                  className="thread-origin-source"
                  onClick={() => onOpenPDFDestination(threadSourceURL(activeThread)!)}
                >
                  {sourceLabel(activeThread)}
                </button>
              ) : <p>{sourceLabel(activeThread)}</p>
            )}
            {anchorChanged && (
              <p className="thread-anchor-warning" role="status">
                The Stream text has changed since this thread started.
              </p>
            )}
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
            {onRequestInsertion && (
              <button
                type="button"
                className="thread-add-to-stream"
                disabled={!workingText.trim() || insertionBlocked}
                onClick={() => { void requestInsertion('note', workingText); }}
              >
                Place in Stream…
              </button>
            )}
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

          <section className="thread-conversation" aria-label="Thread conversation">
            {exchanges.map((exchange) => (
              <ThreadExchange
                key={exchange.requestId}
                exchange={exchange}
                onOpenPDFDestination={onOpenPDFDestination}
                onAddToStream={onRequestInsertion && !insertionBlocked
                  ? (text) => { void requestInsertion('ai', text); }
                  : undefined}
              />
            ))}
            {pendingAI && (
              <article className="thread-exchange thread-exchange--pending" aria-live="polite">
                <div className="thread-user-turn">
                  <span>You</span>
                  <p>{pendingAI.prompt}</p>
                </div>
                <div className="thread-assistant-turn">
                  <span>AI</span>
                  {pendingAI.response ? (
                    <AIResponse
                      markdown={pendingAI.response}
                      sourceManifest={pendingAI.sentContext ? JSON.stringify(pendingAI.sentContext) : '{}'}
                      onOpenPDFDestination={onOpenPDFDestination}
                    />
                  ) : !pendingAI.error ? (
                    <p className="thread-ai-waiting">Thinking…</p>
                  ) : null}
                </div>
                {pendingAI.sentContext && (
                  <SentContext
                    facts={pendingAI.sentContext}
                    onOpenPDFDestination={onOpenPDFDestination}
                  />
                )}
                {pendingAI.error && (
                  <div className="thread-ai-error" role="alert">
                    <p>{pendingAI.error}</p>
                    <button
                      type="button"
                      onClick={() => {
                        setPrompt(pendingAI.prompt);
                        activePromptRef.current = null;
                        setPendingAI(null);
                      }}
                    >
                      Edit and try again
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        activePromptRef.current = null;
                        setPendingAI(null);
                      }}
                    >
                      Dismiss
                    </button>
                  </div>
                )}
              </article>
            )}
          </section>

          <form
            className="thread-prompt"
            onSubmit={(event) => {
              event.preventDefault();
              void sendPrompt();
            }}
          >
            <label htmlFor="thread-ai-prompt">Ask in this thread</label>
            <textarea
              id="thread-ai-prompt"
              aria-label="Ask in this thread"
              value={prompt}
              disabled={Boolean(pendingAI) || preparingAI}
              placeholder="Ask a question or continue the thought…"
              onChange={(event) => setPrompt(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== 'Enter' || (!event.metaKey && !event.ctrlKey)) return;
                event.preventDefault();
                void sendPrompt();
              }}
            />
            <div className="thread-prompt-actions">
              {pendingAI && !pendingAI.error ? (
                <button type="button" onClick={cancelAI}>Stop</button>
              ) : (
                <button
                  type="submit"
                  disabled={!prompt.trim() || saveState !== 'saved' || Boolean(pendingAI) || preparingAI}
                >
                  {preparingAI ? 'Preparing…' : 'Send'}
                </button>
              )}
              {saveState !== 'saved' && <span>Save the note before sending.</span>}
            </div>
          </form>
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
              <time dateTime={thread.updatedAt} title={new Date(thread.updatedAt).toLocaleString()}>
                {relativeTime(thread.updatedAt)}
              </time>
            </button>
          ))}
        </div>
      )}
    </aside>
  );
});
