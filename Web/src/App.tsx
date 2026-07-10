import { useEffect, useRef, useState } from 'react';
import { bridge, Stream, StreamSummary } from './types';
import { StreamEditor } from './components/StreamEditor';
import { SearchModal } from './components/SearchModal';
import { Settings } from './components/Settings';
import { ToastStack } from './components/ToastStack';
import { DocumentIcon, KeyIcon, Spinner } from './components/icons';
import { useToastStore } from './store/toastStore';
import { debugError, debugLog } from './utils/debug';
import { deserializeProvenanceSpans } from './utils/provenanceSpans';

type View = 'list' | 'stream' | 'settings';

// Proxy auth state (matches Swift ProxyAuthState enum)
type ProxyAuthState =
  | 'unregistered'
  | 'validating'
  | 'active'
  | 'blockedInvalid'
  | 'blockedRevoked'
  | 'blockedBoundElsewhere'
  | 'degradedOffline';

type EditorFont = 'systemSans' | 'humanistSans' | 'monoSans';

interface EditorTypographySettings {
  editorFont: EditorFont;
  editorFontSize: number;
  editorLineSpacing: number;
}

const DEFAULT_EDITOR_TYPOGRAPHY: EditorTypographySettings = {
  editorFont: 'systemSans',
  editorFontSize: 16,
  editorLineSpacing: 1.55,
};

function editorFontStack(font: EditorFont): string {
  switch (font) {
    case 'humanistSans':
      return '"Avenir Next", "SF Pro Text", -apple-system, BlinkMacSystemFont, system-ui, sans-serif';
    case 'monoSans':
      return '"SF Mono", "JetBrains Mono", "IBM Plex Sans", Menlo, "SF Pro Text", sans-serif';
    case 'systemSans':
    default:
      return '"SF Pro Text", -apple-system, BlinkMacSystemFont, system-ui, "Helvetica Neue", sans-serif';
  }
}

function normalizeEditorTypography(raw: Partial<EditorTypographySettings> | null | undefined): EditorTypographySettings {
  const merged = { ...DEFAULT_EDITOR_TYPOGRAPHY, ...(raw ?? {}) };
  const validFonts: EditorFont[] = ['systemSans', 'humanistSans', 'monoSans'];
  const editorFont = validFonts.includes(merged.editorFont) ? merged.editorFont : DEFAULT_EDITOR_TYPOGRAPHY.editorFont;
  const editorFontSize = Number.isFinite(Number(merged.editorFontSize))
    ? Math.min(24, Math.max(13, Number(merged.editorFontSize)))
    : DEFAULT_EDITOR_TYPOGRAPHY.editorFontSize;
  const editorLineSpacing = Number.isFinite(Number(merged.editorLineSpacing))
    ? Math.min(2.0, Math.max(1.3, Number(merged.editorLineSpacing)))
    : DEFAULT_EDITOR_TYPOGRAPHY.editorLineSpacing;

  return {
    editorFont,
    editorFontSize: Number(editorFontSize.toFixed(1)),
    editorLineSpacing: Number(editorLineSpacing.toFixed(2)),
  };
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
  const [isLoadingStream, setIsLoadingStream] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const addToast = useToastStore((state) => state.addToast);
  const viewRef = useRef(view);
  const currentStreamIdRef = useRef<string | null>(currentStream?.id ?? null);

  // Proxy auth state - gates main UI until key is validated
  const [proxyAuthState, setProxyAuthState] = useState<ProxyAuthState>('validating');
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
  }, []);

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
        case 'bridgeError':
          if (import.meta.env.DEV) {
            const originalType = String(message.payload?.originalType ?? 'unknown');
            const reason = String(message.payload?.reason ?? 'Unknown bridge error');
            addToast(`Bridge error (${originalType}): ${reason}`, 'error', 10000);
          }
          break;
        case 'proxyAuthState':
          // State change pushed from Swift
          setProxyAuthState(message.payload?.state as ProxyAuthState);
          break;
        case 'streamsLoaded':
          setStreams((message.payload?.streams as StreamSummary[]) || []);
          setIsLoading(false);
          break;
        case 'streamLoaded': {
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
            marginNotes: (Array.isArray(message.payload?.marginNotes) ? message.payload.marginNotes : []) as Stream['marginNotes'],
            document: {
              ...payloadStream.document,
              scrollOffset: Number.isFinite(scrollOffset) ? scrollOffset : 0,
            },
          };
          currentStreamIdRef.current = loadedStream?.id ?? null;
          viewRef.current = 'stream';
          setCurrentStream(loadedStream);
          setIsLoadingStream(false);
          setView('stream');
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
          // Quick Panel appended to a document - if it's a new stream, load it.
          if (message.payload?.isNewStream && message.payload?.streamId) {
            const streamId = message.payload.streamId as string;
            if (viewRef.current === 'stream' && currentStreamIdRef.current === streamId) {
              debugLog('[App] Quick Panel appended to current stream document; editor handler owns it', { streamId });
              break;
            }

            debugLog('[App] Quick Panel created new stream document', { streamId });

            bridge.send({ type: 'loadStream', payload: { id: streamId } });
          }
          break;
        case 'streamsChanged':
          // Quick Panel created a new stream - reload the list
          debugLog('[App] Streams changed, reloading list');
          bridge.send({ type: 'loadStreams' });
          break;
      }
    });

    // Request initial data after a short delay to ensure bridge is ready
    setTimeout(() => {
      bridge.send({ type: 'loadStreams' });
    }, 100);

    return unsubscribe;
  }, [addToast]);

  const handleCreateStream = () => {
    bridge.send({ type: 'createStream' });
  };

  const handleSelectStream = (id: string) => {
    setIsLoadingStream(true);
    bridge.send({ type: 'loadStream', payload: { id } });
  };

  const handleBackToList = () => {
    setCurrentStream(null);
    setView('list');
    bridge.send({ type: 'loadStreams' });
  };

  const handleDeleteStream = () => {
    if (currentStream) {
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

    setIsLoadingStream(true);
    bridge.send({ type: 'loadStream', payload: { id: streamId } });
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

  let viewContent: JSX.Element;

  // Always allow settings view (for key entry)
  if (view === 'settings') {
    viewContent = <Settings onClose={handleCloseSettings} />;
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
    viewContent = (
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
        isLoadingStream={isLoadingStream}
        onSelect={handleSelectStream}
        onCreate={handleCreateStream}
        onSettings={handleOpenSettings}
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
    </>
  );
}

interface StreamListViewProps {
  streams: StreamSummary[];
  isLoading: boolean;
  isLoadingStream: boolean;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onSettings: () => void;
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
  if (diffDays < 7) return `${diffDays}d ago`;
  return date.toLocaleDateString();
}

function formatCompactCount(count: number): string {
  if (count < 1000) {
    return new Intl.NumberFormat().format(count);
  }
  return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(count / 1000)}k`;
}

function formatStreamMetadata(stream: StreamSummary): string {
  const segments = [formatRelativeTime(stream.updatedAt)];

  if (stream.sourceCount === 1) {
    segments.push(stream.sourceShortTitle ?? '1 source');
  } else if (stream.sourceCount > 1) {
    segments.push(`${stream.sourceCount} sources`);
  }
  segments.push(`${formatCompactCount(stream.wordCount)} ${stream.wordCount === 1 ? 'word' : 'words'}`);
  if (stream.imageCount > 0) {
    segments.push(`${stream.imageCount} ${stream.imageCount === 1 ? 'image' : 'images'}`);
  }

  return segments.join(' · ');
}

function StreamListView({ streams, isLoading, isLoadingStream, onSelect, onCreate, onSettings }: StreamListViewProps) {
  // Sort streams by updatedAt (most recent first)
  const sortedStreams = [...streams].sort((a, b) =>
    new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
  );

  return (
    <div className="stream-list">
      <header className="stream-list-header">
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
              className={`stream-item ${isLoadingStream ? 'stream-item--loading' : ''}`}
              onClick={() => onSelect(stream.id)}
              disabled={isLoadingStream}
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
                {formatStreamMetadata(stream)}
              </span>
            </button>
          ))
        )}
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
