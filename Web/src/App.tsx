import { useEffect, useRef, useState } from 'react';
import { bridge, Stream, StreamSummary, type AIOperationState } from './types';
import { StreamEditor } from './components/StreamEditor';
import { RichStreamEditor } from './components/RichStreamEditor';

/**
 * Which editor the stream page uses.
 *
 * ProseMirror owns the canonical document. External writers queue Markdown
 * commands for it to reduce; the Markdown sent back on save is a projection for
 * search, AI, and export.
 *
 * docs/RICHTEXT_VERDICT.md has the full analysis and the options.
 */
const USE_RICH_TEXT_EDITOR = true;
import { SearchModal } from './components/SearchModal';
import { Settings } from './components/Settings';
import { ToastStack } from './components/ToastStack';
import { DocumentIcon, KeyIcon, Spinner, XIcon } from './components/icons';
import { useToastStore } from './store/toastStore';
import { debugError, debugLog } from './utils/debug';
import { deserializeProvenanceSpans } from './utils/provenanceSpans';
import {
  editorFontStack,
  normalizeEditorTypography,
  type EditorTypographySettings,
} from './utils/editorTypography';

type View = 'list' | 'stream' | 'settings';
type StorageState = 'checking' | 'ready' | 'unavailable';

const AI_OPERATION_STATES: AIOperationState[] = [
  'queued',
  'preparing',
  'generating',
  'saving',
  'succeeded',
  'failed',
  'canceled',
];

export interface AIOperationActivity {
  requestId: string;
  streamId: string;
  verb: string;
  origin: string;
  state: AIOperationState;
  message?: string;
  updatedAt: number;
}

export function parseAIOperationActivity(
  payload: Record<string, unknown> | undefined,
  updatedAt = Date.now()
): AIOperationActivity | null {
  const requestId = payload?.requestId;
  const streamId = payload?.streamId;
  const verb = payload?.verb;
  const origin = payload?.origin;
  const state = payload?.state;
  if (typeof requestId !== 'string'
      || typeof streamId !== 'string'
      || typeof verb !== 'string'
      || typeof origin !== 'string'
      || !AI_OPERATION_STATES.includes(state as AIOperationState)) {
    return null;
  }

  return {
    requestId,
    streamId,
    verb,
    origin,
    state: state as AIOperationState,
    ...(typeof payload?.message === 'string' ? { message: payload.message } : {}),
    updatedAt,
  };
}

export function aiOperationActionLabel(
  operation: Pick<AIOperationActivity, 'origin' | 'verb'>
): string {
  if (operation.origin === 'pdfSection') {
    return operation.verb === 'summarize'
      ? 'Summarizing a PDF section'
      : 'Answering a PDF section question';
  }
  if (operation.origin === 'quickPanel' && operation.verb === 'develop') return 'Developing';
  return 'AI work';
}

// Proxy auth state (matches Swift ProxyAuthState enum)
type ProxyAuthState =
  | 'unregistered'
  | 'validating'
  | 'active'
  | 'blockedInvalid'
  | 'blockedRevoked'
  | 'blockedBoundElsewhere'
  | 'degradedOffline';

export function shouldAcceptStreamLoaded(requestId: unknown, pendingRequestId: number | null): boolean {
  if (requestId === undefined) return pendingRequestId === null;
  return typeof requestId === 'number' && Number.isInteger(requestId) && requestId === pendingRequestId;
}

function applyEditorTypography(settings: EditorTypographySettings) {
  const root = document.documentElement;
  root.style.setProperty('--editor-font-family', editorFontStack(settings.editorFont));
  root.style.setProperty('--editor-font-size', `${settings.editorFontSize}px`);
  root.style.setProperty('--editor-line-height', String(settings.editorLineSpacing));
}

export function App() {
  const [view, setView] = useState<View>('list');
  const [streams, setStreams] = useState<StreamSummary[]>([]);
  const [currentStream, setCurrentStream] = useState<Stream | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [streamListError, setStreamListError] = useState<string | null>(null);
  const [showSearch, setShowSearch] = useState(false);
  const [aiOperations, setAIOperations] = useState<Map<string, AIOperationActivity>>(new Map());
  const addToast = useToastStore((state) => state.addToast);
  const viewRef = useRef(view);
  const currentStreamIdRef = useRef<string | null>(currentStream?.id ?? null);
  const streamLoadSequenceRef = useRef(0);
  const pendingStreamLoadRef = useRef<{ streamId: string; requestId: number } | null>(null);
  const aiOperationDismissTimersRef = useRef<Map<string, number>>(new Map());
  const editorFlushRef = useRef<(() => Promise<boolean>) | null>(null);

  const requestStreamLoad = async (id: string) => {
    if (viewRef.current === 'stream'
        && currentStreamIdRef.current !== id
        && editorFlushRef.current
        && !await editorFlushRef.current()) {
      addToast('Your changes could not be saved, so this stream stayed open.', 'error');
      return;
    }
    const requestId = ++streamLoadSequenceRef.current;
    pendingStreamLoadRef.current = { streamId: id, requestId };
    bridge.send({ type: 'loadStream', payload: { id, requestId } });
  };

  // Proxy auth state - gates main UI until key is validated
  const [proxyAuthState, setProxyAuthState] = useState<ProxyAuthState>('validating');
  const [storageState, setStorageState] = useState<StorageState>('checking');
  const isAuthGated = proxyAuthState !== 'active' && proxyAuthState !== 'degradedOffline';

  // Load initial proxy auth state
  useEffect(() => {
    bridge.sendAsync<{ state: ProxyAuthState }>('loadProxyAuth')
      .then((result) => {
        setProxyAuthState(result.state);
      })
      .catch(() => {
        debugError('Failed to load proxy auth');
        setProxyAuthState('unregistered');
      });
  }, []);

  // Load global editor typography settings on app startup.
  useEffect(() => {
    bridge.send({ type: 'loadSettings' });
    bridge.send({ type: 'loadStorageState' });
  }, []);

  useEffect(() => {
    if (storageState !== 'ready') return undefined;
    const timeout = window.setTimeout(() => bridge.send({ type: 'loadStreams' }), 100);
    return () => window.clearTimeout(timeout);
  }, [storageState]);

  useEffect(() => {
    viewRef.current = view;
    currentStreamIdRef.current = currentStream?.id ?? null;
  }, [view, currentStream?.id]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey)) return;
      const key = event.key.toLowerCase();
      // ⌘K everywhere; ⌘F only outside the editor (inside, it's in-document find).
      if (key !== 'k' && !(key === 'f' && viewRef.current === 'list')) return;
      const canSearch = viewRef.current === 'list' || (viewRef.current === 'stream' && currentStreamIdRef.current);
      if (isAuthGated || !canSearch) return;
      event.preventDefault();
      setShowSearch(true);
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isAuthGated]);

  // Keep native file-drop routing in sync with the active page.
  useEffect(() => {
    if (view === 'stream' && currentStream) {
      bridge.send({
        type: 'setFileDropContext',
        payload: { mode: 'stream', streamId: currentStream.id },
      });
      return;
    }

    if (view === 'list') {
      bridge.send({
        type: 'setFileDropContext',
        payload: { mode: 'list' },
      });
      return;
    }

    bridge.send({
      type: 'setFileDropContext',
      payload: { mode: 'disabled' },
    });
  }, [view, currentStream]);

  useEffect(() => {
    // Subscribe to bridge messages
    const unsubscribe = bridge.onMessage((message) => {
      switch (message.type) {
        case 'flushEditor': {
          const requestId = message.payload?.requestId;
          if (typeof requestId === 'string' && viewRef.current !== 'stream') {
            bridge.send({ type: 'editorFlushed', payload: { requestId } });
          }
          break;
        }
        case 'bridgeError':
          if (import.meta.env.DEV) {
            const originalType = String(message.payload?.originalType ?? 'unknown');
            const reason = String(message.payload?.reason ?? 'Unknown bridge error');
            addToast(`Bridge error (${originalType}): ${reason}`, 'error', 10000);
          } else {
            addToast('Ticker could not complete that action. Try again.', 'error');
          }
          break;
        case 'aiOperationChanged': {
          const operation = parseAIOperationActivity(message.payload);
          if (!operation) break;

          const previousTimer = aiOperationDismissTimersRef.current.get(operation.requestId);
          if (previousTimer !== undefined) window.clearTimeout(previousTimer);
          aiOperationDismissTimersRef.current.delete(operation.requestId);

          setAIOperations((current) => {
            const next = new Map(current);
            next.set(operation.requestId, operation);
            return next;
          });

          if (operation.state === 'succeeded' || operation.state === 'failed' || operation.state === 'canceled') {
            const timeout = window.setTimeout(() => {
              aiOperationDismissTimersRef.current.delete(operation.requestId);
              setAIOperations((current) => {
                const next = new Map(current);
                next.delete(operation.requestId);
                return next;
              });
            }, operation.state === 'failed' ? 10_000 : 4_000);
            aiOperationDismissTimersRef.current.set(operation.requestId, timeout);
          }
          break;
        }
        case 'proxyAuthState':
          // State change pushed from Swift
          setProxyAuthState(message.payload?.state as ProxyAuthState);
          break;
        case 'storageStateChanged': {
          const state = message.payload?.state;
          if (state !== 'ready' && state !== 'unavailable') break;
          setStorageState(state);
          if (state === 'unavailable') {
            setIsLoading(false);
          }
          break;
        }
        case 'streamsLoaded':
          setStreams((message.payload?.streams as StreamSummary[]) || []);
          setStreamListError(null);
          setIsLoading(false);
          break;
        case 'streamsLoadFailed':
          setIsLoading(false);
          setStreamListError('Ticker could not load your streams.');
          break;
        case 'streamLoaded': {
          const requestId = message.payload?.requestId;
          if (!shouldAcceptStreamLoaded(requestId, pendingStreamLoadRef.current?.requestId ?? null)) break;
          pendingStreamLoadRef.current = null;
          const payloadStream = message.payload?.stream as Stream | undefined;
          if (!payloadStream) break;
          const scrollOffset = Number(message.payload?.scrollOffset ?? payloadStream?.document?.scrollOffset ?? 0);
          const payloadSourceScope = message.payload?.sourceScope;
          const sourceScope: Stream['sourceScope'] = payloadSourceScope === 'auto'
            || payloadSourceScope === 'all'
            || payloadSourceScope === 'none'
            ? payloadSourceScope
            : payloadStream.sourceScope ?? 'auto';
          const loadedStream = {
            ...payloadStream,
            sourceScope,
            spans: deserializeProvenanceSpans(message.payload?.spans),
            // Appends made while no editor was open; the editor converts their
            // provenance out of fragment coordinates the first time it opens.
            pendingAppends: (Array.isArray(message.payload?.pendingAppends)
              ? message.payload.pendingAppends
              : []) as Stream['pendingAppends'],
            appendInbox: (Array.isArray(message.payload?.appendInbox)
              ? message.payload.appendInbox
              : []) as Stream['appendInbox'],
            marginNotes: (Array.isArray(message.payload?.marginNotes) ? message.payload.marginNotes : []) as Stream['marginNotes'],
            document: {
              ...payloadStream.document,
              scrollOffset: Number.isFinite(scrollOffset) ? scrollOffset : 0,
            },
          };
          currentStreamIdRef.current = loadedStream?.id ?? null;
          viewRef.current = 'stream';
          setCurrentStream(loadedStream);
          setView('stream');
          break;
        }
        case 'streamLoadFailed': {
          const requestId = message.payload?.requestId;
          if (!shouldAcceptStreamLoaded(requestId, pendingStreamLoadRef.current?.requestId ?? null)) break;
          pendingStreamLoadRef.current = null;
          addToast(
            message.payload?.reason === 'notFound'
              ? 'That stream no longer exists.'
              : 'Ticker could not open that stream. Try again.',
            'error'
          );
          break;
        }
        case 'marginNotesChanged': {
          const streamId = message.payload?.streamId as string | undefined;
          const notes = (Array.isArray(message.payload?.notes) ? message.payload.notes : []) as Stream['marginNotes'];
          if (streamId && streamId === currentStreamIdRef.current) {
            setCurrentStream((stream) => stream ? { ...stream, marginNotes: notes } : stream);
          }
          break;
        }
        case 'settingsLoaded': {
          const raw = message.payload?.settings as Partial<EditorTypographySettings> | undefined;
          applyEditorTypography(normalizeEditorTypography(raw));
          break;
        }
        case 'streamDocumentAppended':
          // A first Quick Panel capture creates its stream before any editor exists.
          if (message.payload?.isNewStream && message.payload?.streamId) {
            const streamId = message.payload.streamId as string;
            if (viewRef.current === 'stream' && currentStreamIdRef.current === streamId) {
              debugLog('[App] Quick Panel appended to current stream document; editor handler owns it', { streamId });
              break;
            }

            debugLog('[App] Quick Panel created new stream document', { streamId });

            requestStreamLoad(streamId);
          }
          break;
        case 'streamAppendInboxChanged': {
          const streamId = message.payload?.streamId;
          const appendInbox = message.payload?.appendInbox;
          if (typeof streamId !== 'string' || !Array.isArray(appendInbox)) break;

          if (currentStreamIdRef.current === streamId) {
            // The message can land after App accepts streamLoaded but before React
            // mounts its editor listener. Keeping the snapshot in props lets that
            // first mount reduce it instead of losing the only live notification.
            setCurrentStream((current) => current?.id === streamId
              ? { ...current, appendInbox: appendInbox as Stream['appendInbox'] }
              : current);
            break;
          }

          if (pendingStreamLoadRef.current?.streamId === streamId || message.payload?.isNewStream) {
            // A snapshot read before this enqueue cannot contain the row. Supersede
            // that load so the accepted response describes a state after the write.
            requestStreamLoad(streamId);
          }
          break;
        }
        case 'streamsChanged':
          // Quick Panel created a new stream - reload the list
          debugLog('[App] Streams changed, reloading list');
          bridge.send({ type: 'loadStreams' });
          break;
      }
    });

    return () => {
      unsubscribe();
      for (const timeout of aiOperationDismissTimersRef.current.values()) {
        window.clearTimeout(timeout);
      }
      aiOperationDismissTimersRef.current.clear();
    };
  }, [addToast]);

  const handleCreateStream = () => {
    pendingStreamLoadRef.current = null;
    bridge.send({ type: 'createStream' });
  };

  const handleSelectStream = (id: string) => {
    requestStreamLoad(id);
  };

  const handleBackToList = () => {
    pendingStreamLoadRef.current = null;
    setCurrentStream(null);
    setView('list');
    bridge.send({ type: 'loadStreams' });
  };

  const handleDeleteStream = () => {
    if (currentStream) {
      pendingStreamLoadRef.current = null;
      bridge.send({ type: 'deleteStream', payload: { id: currentStream.id } });
      setCurrentStream(null);
      setView('list');
    }
  };

  // Navigate to a different stream and scroll to a text match or a source
  const [pendingMatchText, setPendingMatchText] = useState<string | null>(null);
  const [pendingSourceId, setPendingSourceId] = useState<string | null>(null);

  const handleNavigateToStream = (streamId: string, targetId: string, targetType: 'match' | 'source' = 'match') => {
    if (targetType === 'source') {
      setPendingSourceId(targetId);
      setPendingMatchText(null);
    } else {
      setPendingMatchText(targetId);
      setPendingSourceId(null);
    }

    if (viewRef.current === 'stream' && currentStreamIdRef.current === streamId) {
      setView('stream');
      return;
    }

    requestStreamLoad(streamId);
  };

  const handleNavigateToMatch = (matchText: string) => {
    setPendingMatchText(matchText);
    setPendingSourceId(null);
  };

  const handleNavigateToSource = (sourceId: string) => {
    setPendingSourceId(sourceId);
    setPendingMatchText(null);
  };

  const handleOpenSettings = () => {
    setView('settings');
  };

  const handleCloseSettings = () => {
    setView('list');
  };

  const handleCopyDiagnostics = async () => {
    try {
      const result = await bridge.sendAsync<{ bundle: Record<string, unknown> }>('getSupportBundle');
      await navigator.clipboard.writeText(JSON.stringify(result.bundle, null, 2));
      addToast('Diagnostics copied to clipboard.', 'success');
    } catch {
      addToast('Diagnostics could not be copied.', 'error');
    }
  };

  const handleRetryStreamList = () => {
    setStreamListError(null);
    setIsLoading(true);
    bridge.send({ type: 'loadStreams' });
  };

  let viewContent: JSX.Element;

  // Always allow settings view (for key entry)
  if (view === 'settings') {
    viewContent = <Settings onClose={handleCloseSettings} />;
  } else if (storageState === 'unavailable') {
    viewContent = (
      <StorageGate
        onOpenSettings={handleOpenSettings}
        onCopyDiagnostics={handleCopyDiagnostics}
        onQuit={() => bridge.send({ type: 'quitApp' })}
      />
    );
  } else if (storageState === 'checking') {
    viewContent = (
      <div className="loading-state">
        <Spinner className="loading-spinner" />
        <p>Opening notes...</p>
      </div>
    );
  } else if (isAuthGated) {
    // Gate main UI until authenticated
    viewContent = (
      <AuthGate
        state={proxyAuthState}
        onOpenSettings={handleOpenSettings}
      />
    );
  } else if (view === 'stream' && currentStream) {
    // key={currentStream.id} forces React to remount the editor when switching streams.
    // This ensures stream-local editor state does not leak across streams.
    viewContent = USE_RICH_TEXT_EDITOR ? (
      <RichStreamEditor
        key={currentStream.id}
        stream={currentStream}
        onBack={handleBackToList}
        onDelete={handleDeleteStream}
        onFlushAvailable={(flush) => { editorFlushRef.current = flush; }}
        pendingMatchText={pendingMatchText}
        pendingSourceId={pendingSourceId}
        onClearPendingMatch={() => setPendingMatchText(null)}
        onClearPendingSource={() => setPendingSourceId(null)}
      />
    ) : (
      <StreamEditor
        key={currentStream.id}
        stream={currentStream}
        onBack={handleBackToList}
        onDelete={handleDeleteStream}
        pendingMatchText={pendingMatchText}
        pendingSourceId={pendingSourceId}
        onClearPendingMatch={() => setPendingMatchText(null)}
        onClearPendingSource={() => setPendingSourceId(null)}
      />
    );
  } else {
    viewContent = (
      <StreamListView
        streams={streams}
        isLoading={isLoading}
        error={streamListError}
        onSelect={handleSelectStream}
        onCreate={handleCreateStream}
        onSettings={handleOpenSettings}
        onRetry={handleRetryStreamList}
      />
    );
  }

  return (
    <>
      {viewContent}
      <SearchModal
        isOpen={showSearch}
        onClose={() => setShowSearch(false)}
        currentStreamId={view === 'stream' ? currentStream?.id ?? null : null}
        isStreamOpen={view === 'stream' && currentStream !== null}
        onNavigateToMatch={handleNavigateToMatch}
        onNavigateToStream={handleNavigateToStream}
        onNavigateToSource={handleNavigateToSource}
      />
      <ToastStack />
      <AIActivityCapsule
        operations={[...aiOperations.values()].sort((a, b) => b.updatedAt - a.updatedAt)}
        streams={streams}
        currentStream={currentStream}
        onCancel={(requestId) => bridge.send({ type: 'cancelAIOperation', payload: { requestId } })}
      />
    </>
  );
}

interface AIActivityCapsuleProps {
  operations: AIOperationActivity[];
  streams: StreamSummary[];
  currentStream: Stream | null;
  onCancel: (requestId: string) => void;
}

function AIActivityCapsule({ operations, streams, currentStream, onCancel }: AIActivityCapsuleProps) {
  if (operations.length === 0) return null;

  const streamTitle = (streamId: string) => {
    if (currentStream?.id === streamId) return currentStream.title;
    return streams.find((stream) => stream.id === streamId)?.title ?? 'Stream';
  };

  const phaseLabel = (state: AIOperationState) => {
    switch (state) {
      case 'queued': return 'Queued';
      case 'preparing': return 'Preparing';
      case 'generating': return 'Writing';
      case 'saving': return 'Saving';
      case 'succeeded': return 'Saved';
      case 'failed': return 'Failed';
      case 'canceled': return 'Canceled';
    }
  };

  return (
    <section className="ai-activity-capsule" aria-label="AI activity" aria-live="polite">
      {operations.slice(0, 4).map((operation) => {
        const isActive = operation.state !== 'succeeded'
          && operation.state !== 'failed'
          && operation.state !== 'canceled';
        return (
          <div className="ai-activity-row" data-state={operation.state} key={operation.requestId}>
            {isActive ? <Spinner className="ai-activity-spinner" /> : <span className="ai-activity-dot" aria-hidden="true" />}
            <span className="ai-activity-copy">
              <span className="ai-activity-label">{aiOperationActionLabel(operation)}</span>
              <span className="ai-activity-stream">
                {phaseLabel(operation.state)} · {streamTitle(operation.streamId)}
              </span>
              {operation.state === 'failed' && operation.message && (
                <span className="ai-activity-message">{operation.message}</span>
              )}
            </span>
            {isActive && (
              <button
                type="button"
                className="ai-activity-cancel"
                onClick={() => onCancel(operation.requestId)}
                aria-label={`Stop AI in ${streamTitle(operation.streamId)}`}
              >
                <XIcon size={12} /> Stop
              </button>
            )}
          </div>
        );
      })}
      {operations.length > 4 && <div className="ai-activity-more">+{operations.length - 4} more</div>}
    </section>
  );
}

interface StreamListViewProps {
  streams: StreamSummary[];
  isLoading: boolean;
  error: string | null;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onSettings: () => void;
  onRetry: () => void;
}

function formatRelativeTime(dateString: string): string {
  const date = new Date(dateString);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 30) return `${diffDays}d ago`;
  if (diffDays < 365) return `${Math.floor(diffDays / 30)}mo ago`;
  return `${Math.floor(diffDays / 365)}y ago`;
}

function StreamListView({ streams, isLoading, error, onSelect, onCreate, onSettings, onRetry }: StreamListViewProps) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const update = () => setScrolled(window.scrollY > 0);
    update();
    window.addEventListener('scroll', update, { passive: true });
    return () => window.removeEventListener('scroll', update);
  }, []);

  // Sort streams by updatedAt (most recent first)
  const sortedStreams = [...streams].sort((a, b) =>
    new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );

  return (
    <div className="stream-list">
      <header className={`stream-list-header ${scrolled ? 'stream-list-header--scrolled' : ''}`}>
        <h1>Streams</h1>
        <div className="stream-list-actions">
          <button onClick={onSettings} className="settings-button">
            Settings
          </button>
          <button onClick={onCreate} className="primary-button">New Stream</button>
        </div>
      </header>
      <div className="stream-list-content">
        {isLoading ? (
          <div className="loading-state">
            <Spinner className="loading-spinner" />
            <p>Loading...</p>
          </div>
        ) : error ? (
          <div className="empty-state">
            <div className="empty-state-icon"><DocumentIcon size={56} /></div>
            <h2>Streams unavailable</h2>
            <p>{error}</p>
            <button onClick={onRetry} className="primary-button">Try again</button>
          </div>
        ) : streams.length === 0 ? (
          <div className="empty-state">
            <div className="empty-state-icon"><DocumentIcon size={56} /></div>
            <h2>No streams yet</h2>
            <p>Create a stream to start capturing your thoughts.</p>
            <button onClick={onCreate} className="primary-button">Create your first stream</button>
          </div>
        ) : (
          sortedStreams.map((stream) => (
            <button
              key={stream.id}
              className="stream-item"
              onClick={() => onSelect(stream.id)}
            >
              <span className="stream-title-row">
                <span className="stream-title">{stream.title}</span>
                {stream.openQuestionCount > 0 && (
                  <span className="stream-open-questions">
                    {stream.openQuestionCount} open {stream.openQuestionCount === 1 ? 'question' : 'questions'}
                  </span>
                )}
              </span>
              {stream.previewLine && (
                <span className="stream-preview">{stream.previewLine}</span>
              )}
              <span className="stream-meta">
                {formatRelativeTime(stream.updatedAt)}
              </span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}

interface StorageGateProps {
  onOpenSettings: () => void;
  onCopyDiagnostics: () => void;
  onQuit: () => void;
}

function StorageGate({ onOpenSettings, onCopyDiagnostics, onQuit }: StorageGateProps) {
  return (
    <div className="auth-gate">
      <div className="auth-gate-content">
        <div className="auth-gate-icon"><DocumentIcon size={48} /></div>
        <h1>Notes unavailable</h1>
        <p>
          Ticker could not open its local database. Settings and diagnostics are still available;
          quit and reopen Ticker after checking disk access.
        </p>
        <div className="storage-gate-actions">
          <button type="button" className="primary-button" onClick={onOpenSettings}>Open Settings</button>
          <button type="button" className="settings-support-bundle-btn" onClick={onCopyDiagnostics}>Copy Diagnostics</button>
          <button type="button" className="settings-button" onClick={onQuit}>Quit Ticker</button>
        </div>
      </div>
    </div>
  );
}

// Auth gate - shown when device key is not validated
interface AuthGateProps {
  state: ProxyAuthState;
  onOpenSettings: () => void;
}

function AuthGate({ state, onOpenSettings }: AuthGateProps) {
  let title: string;
  let message: string;
  let showButton = true;

  switch (state) {
    case 'validating':
      title = 'Connecting...';
      message = 'Validating your device key with Ticker.';
      showButton = false;
      break;
    case 'blockedInvalid':
      title = 'Invalid Device Key';
      message = 'Your device key is invalid or has expired. Please enter a valid key.';
      break;
    case 'blockedRevoked':
      title = 'Key Revoked';
      message = 'Your device key has been revoked. Contact support for assistance.';
      break;
    case 'blockedBoundElsewhere':
      title = 'Key Already Used';
      message = 'This device key is bound to a different device. Contact support for assistance.';
      break;
    case 'unregistered':
    default:
      title = 'Welcome to Ticker';
      message = 'Enter your device key to get started.';
      break;
  }

  return (
    <div className="auth-gate">
      <div className="auth-gate-content">
        <div className="auth-gate-icon"><KeyIcon size={48} /></div>
        <h1>{title}</h1>
        <p>{message}</p>
        {state === 'validating' && <Spinner className="loading-spinner" />}
        {showButton && (
          <button onClick={onOpenSettings} className="primary-button">
            {state === 'unregistered' ? 'Enter Device Key' : 'Update Device Key'}
          </button>
        )}
      </div>
    </div>
  );
}

export default App;
