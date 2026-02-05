import { useEffect, useState } from 'react';
import { bridge, Stream, StreamSummary } from './types';
import { StreamEditor } from './components/StreamEditor';
import { UnifiedStreamEditor } from './components/UnifiedStreamEditor';
import { Settings } from './components/Settings';
import { ToastStack } from './components/ToastStack';
import { useBlockStore } from './store/blockStore';
import { isUnifiedEditorEnabled } from './utils/featureFlags';
import { debugError, debugLog } from './utils/debug';

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

export function App() {
  const [view, setView] = useState<View>('list');
  const [streams, setStreams] = useState<StreamSummary[]>([]);
  const [currentStream, setCurrentStream] = useState<Stream | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingStream, setIsLoadingStream] = useState(false);
  const clearStream = useBlockStore((state) => state.clearStream);

  // Proxy auth state - gates main UI until key is validated
  const [proxyAuthState, setProxyAuthState] = useState<ProxyAuthState>('validating');

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

  useEffect(() => {
    // Subscribe to bridge messages
    const unsubscribe = bridge.onMessage((message) => {
      switch (message.type) {
        case 'proxyAuthState':
          // State change pushed from Swift
          setProxyAuthState(message.payload?.state as ProxyAuthState);
          break;
        case 'streamsLoaded':
          setStreams((message.payload?.streams as StreamSummary[]) || []);
          setIsLoading(false);
          break;
        case 'streamLoaded':
          setCurrentStream(message.payload?.stream as Stream);
          setIsLoadingStream(false);
          setView('stream');
          break;
        case 'quickPanelCellsAdded':
          // Quick Panel added cells - if it's a new stream, load it and update list
          if (message.payload?.isNewStream && message.payload?.streamId) {
            const streamId = message.payload.streamId as string;
            const cellCount = (message.payload.cells as unknown[])?.length || 0;
            debugLog('[App] Quick Panel created new stream with cells', { streamId, cellCount });

            // Add to streams list so it appears when navigating back
            setStreams(prev => {
              // Avoid duplicates
              if (prev.some(s => s.id === streamId)) return prev;
              return [{
                id: streamId,
                title: 'Untitled',
                sourceCount: 0,
                cellCount,
                updatedAt: new Date().toISOString(),
                previewText: null
              }, ...prev];
            });

            // Load the stream from DB - cells are already saved
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
  }, []);

  const handleCreateStream = () => {
    bridge.send({ type: 'createStream' });
  };

  const handleSelectStream = (id: string) => {
    setIsLoadingStream(true);
    bridge.send({ type: 'loadStream', payload: { id } });
  };

  const handleBackToList = () => {
    clearStream();
    setCurrentStream(null);
    setView('list');
    bridge.send({ type: 'loadStreams' });
  };

  const handleDeleteStream = () => {
    if (currentStream) {
      bridge.send({ type: 'deleteStream', payload: { id: currentStream.id } });
      clearStream();
      setCurrentStream(null);
      setView('list');
    }
  };

  // Navigate to a different stream and scroll to a specific cell or source
  const [pendingCellId, setPendingCellId] = useState<string | null>(null);
  const [pendingSourceId, setPendingSourceId] = useState<string | null>(null);

  const handleNavigateToStream = (streamId: string, targetId: string, targetType: 'cell' | 'source' = 'cell') => {
    if (targetType === 'source') {
      setPendingSourceId(targetId);
      setPendingCellId(null);
    } else {
      setPendingCellId(targetId);
      setPendingSourceId(null);
    }
    setIsLoadingStream(true);
    bridge.send({ type: 'loadStream', payload: { id: streamId } });
  };

  const handleOpenSettings = () => {
    setView('settings');
  };

  const handleCloseSettings = () => {
    setView('list');
  };

  // Check if auth state requires gate
  const isAuthGated = proxyAuthState !== 'active' && proxyAuthState !== 'degradedOffline';

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
    // Feature flag: use unified editor for cross-cell selection support
    const EditorComponent = isUnifiedEditorEnabled() ? UnifiedStreamEditor : StreamEditor;

    // key={currentStream.id} forces React to remount the editor when switching streams.
    // This ensures TipTap reinitializes with the correct content and avoids stale doc state.
    viewContent = (
      <EditorComponent
        key={currentStream.id}
        stream={currentStream}
        onBack={handleBackToList}
        onDelete={handleDeleteStream}
        onNavigateToStream={handleNavigateToStream}
        pendingCellId={pendingCellId}
        pendingSourceId={pendingSourceId}
        onClearPendingCell={() => setPendingCellId(null)}
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
            <div className="loading-spinner" />
            <p>Loading...</p>
          </div>
        ) : streams.length === 0 ? (
          <div className="empty-state">
            <div className="empty-state-icon">📝</div>
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
              <span className="stream-title">{stream.title}</span>
              <span className="stream-meta">
                {formatRelativeTime(stream.updatedAt)} · {stream.sourceCount} {stream.sourceCount === 1 ? 'source' : 'sources'} · {stream.cellCount} {stream.cellCount === 1 ? 'cell' : 'cells'}
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
        <div className="auth-gate-icon">🔑</div>
        <h1>{title}</h1>
        <p>{message}</p>
        {state === 'validating' && <div className="loading-spinner" />}
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
