import { memo, useEffect, useRef, type KeyboardEvent } from 'react';
import { bridge, loadStreamThread } from '../types/bridge';
import type { AIExchangeJSON, SourceScope, StreamThreadJSON } from '../types/models';

export interface ConversationActiveTurn {
  requestId: string;
  userInput: string;
  response: string;
  running: boolean;
  error?: string;
}

export interface ConversationLiveState {
  thread: StreamThreadJSON | null;
  exchanges: AIExchangeJSON[];
  composer: string;
  active: ConversationActiveTurn | null;
  loading: boolean;
  loadError: boolean;
  creating: boolean;
  closing: boolean;
  error: string | null;
}

export const initialConversationLiveState = (threadId?: string): ConversationLiveState => ({
  thread: null,
  exchanges: [],
  composer: '',
  active: null,
  loading: Boolean(threadId),
  loadError: false,
  creating: false,
  closing: false,
  error: null,
});

type ConversationLiveStateUpdater = (current: ConversationLiveState) => ConversationLiveState;

interface ConversationSurfaceProps {
  conversationKey: string;
  streamId: string;
  sourceScope: SourceScope;
  threadId?: string;
  anchorText: string;
  focusComposer: boolean;
  state: ConversationLiveState;
  updateState: (key: string, updater: ConversationLiveStateUpdater) => void;
  createThread: (query: string) => Promise<StreamThreadJSON>;
  hasDrifted: (anchorText: string) => boolean;
  onCollapse: () => void;
}

const copy = (text: string) => void navigator.clipboard?.writeText(text);

const Turn = memo(function Turn({ who, text }: { who: 'You' | 'AI'; text: string }) {
  return (
    <div className={`conversation-turn conversation-turn--${who === 'You' ? 'you' : 'ai'}`}>
      <span className="conversation-turn-label">{who}</span>
      <div className="conversation-turn-text">{text}</div>
      <button type="button" className="conversation-turn-copy" onClick={() => copy(text)}>Copy</button>
    </div>
  );
});

export function ConversationSurface({
  conversationKey,
  streamId,
  sourceScope,
  threadId,
  anchorText,
  focusComposer,
  state,
  updateState,
  createThread,
  hasDrifted,
  onCollapse,
}: ConversationSurfaceProps) {
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const stateRef = useRef(state);
  const activeRequestId = useRef(state.active?.running ? state.active.requestId : null);
  stateRef.current = state;
  activeRequestId.current = state.active?.running ? state.active.requestId : null;

  useEffect(() => {
    if (!threadId || state.thread || !state.loading) return undefined;
    let live = true;
    void loadStreamThread(streamId, threadId)
      .then(({ thread: loaded }) => {
        if (!live) return;
        updateState(conversationKey, (current) => ({
          ...current,
          thread: loaded,
          exchanges: loaded.exchanges ?? [],
          loading: false,
          loadError: false,
        }));
      })
      .catch(() => {
        if (!live) return;
        updateState(conversationKey, (current) => ({
          ...current,
          loading: false,
          loadError: true,
        }));
      });
    return () => { live = false; };
  }, [conversationKey, state.loading, state.thread, streamId, threadId, updateState]);

  useEffect(() => {
    if (!focusComposer) return;
    const frame = window.requestAnimationFrame(() => composerRef.current?.focus());
    return () => window.cancelAnimationFrame(frame);
  }, [focusComposer]);

  useEffect(() => bridge.onMessage((message) => {
    const requestId = activeRequestId.current;
    const payload = message.payload as Record<string, unknown> | undefined;
    if (!requestId || payload?.requestId !== requestId) return;
    if (message.type === 'documentAIChunk' && typeof payload.chunk === 'string') {
      updateState(conversationKey, (current) => current.active?.requestId === requestId
        ? { ...current, active: { ...current.active, response: current.active.response + payload.chunk } }
        : current);
      return;
    }
    if (message.type === 'documentAIComplete') {
      activeRequestId.current = null;
      const exchange = payload.exchange as AIExchangeJSON | undefined;
      updateState(conversationKey, (current) => ({
        ...current,
        exchanges: exchange?.requestId === requestId
          ? [...current.exchanges, exchange]
          : current.exchanges,
        active: null,
      }));
      return;
    }
    if (message.type === 'documentAIError') {
      activeRequestId.current = null;
      updateState(conversationKey, (current) => current.active?.requestId === requestId
        ? {
          ...current,
          active: {
            ...current.active,
            running: false,
            error: payload.errorCode === 'cancelled'
              ? 'Stopped.'
              : typeof payload.error === 'string' ? payload.error : 'AI request failed.',
          },
        }
        : current);
    }
  }), [conversationKey, updateState]);

  const send = async () => {
    const snapshot = stateRef.current;
    const query = snapshot.composer.trim();
    if (!query || snapshot.active?.running || snapshot.loading || snapshot.creating) return;
    if (threadId && !snapshot.thread) return;
    let current = snapshot.thread;
    if (!current && !threadId) {
      updateState(conversationKey, (value) => ({ ...value, creating: true, error: null }));
      try {
        current = await createThread(query);
        updateState(conversationKey, (value) => ({ ...value, thread: current!, creating: false }));
      } catch {
        updateState(conversationKey, (value) => ({
          ...value,
          creating: false,
          error: 'This conversation could not be created.',
        }));
        return;
      }
    }
    if (!current) return;
    const requestId = crypto.randomUUID();
    activeRequestId.current = requestId;
    updateState(conversationKey, (value) => ({
      ...value,
      composer: '',
      error: null,
      active: { requestId, userInput: query, response: '', running: true },
    }));
    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId,
        threadId: current.threadId,
        query,
        imageURLs: [],
        sourceScope,
        verb: 'develop',
      },
    });
  };

  const handleComposerKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
      event.preventDefault();
      void send();
    } else if (event.key === 'Escape' && state.composer.length === 0) {
      event.preventDefault();
      onCollapse();
    }
  };

  const retryLoad = () => updateState(conversationKey, (current) => ({
    ...current,
    loading: true,
    loadError: false,
  }));
  const originalAnchorText = state.thread?.anchorText ?? anchorText;
  const sendDisabled = !state.composer.trim() || state.loading || state.creating
    || Boolean(threadId && !state.thread);
  return (
    <section className={`conversation-surface ${state.closing ? 'conversation-surface--closing' : ''}`}>
      <button type="button" className="conversation-rail" aria-label="Collapse conversation" onClick={onCollapse} />
      <div className="conversation-content">
        {hasDrifted(originalAnchorText) && (
          <p className="conversation-drift-note">The passage has changed since this conversation started.</p>
        )}
        {state.loading && <p className="conversation-status">Loading conversation…</p>}
        {state.loadError && (
          <p className="conversation-load-error">
            This conversation could not be loaded. <button type="button" onClick={retryLoad}>Retry</button>
          </p>
        )}
        {state.exchanges.map((exchange) => (
          <div className="conversation-exchange" key={exchange.requestId}>
            <Turn who="You" text={exchange.userInput} />
            <Turn who="AI" text={exchange.responseRaw} />
          </div>
        ))}
        {state.active && (
          <div className="conversation-exchange">
            <Turn who="You" text={state.active.userInput} />
            <Turn who="AI" text={state.active.response || state.active.error || 'Thinking…'} />
          </div>
        )}
        {state.error && <p className="conversation-error" role="alert">{state.error}</p>}
        <div className="conversation-composer-row">
          <textarea
            ref={composerRef}
            className="conversation-composer"
            value={state.composer}
            onChange={(event) => updateState(conversationKey, (current) => ({
              ...current,
              composer: event.target.value,
            }))}
            onKeyDown={handleComposerKeyDown}
            placeholder="Ask — sees this block, the Stream, and sources"
            rows={2}
            aria-label="Conversation message"
          />
          {state.active?.running ? (
            <button
              type="button"
              className="conversation-stop"
              onClick={() => bridge.send({
                type: 'cancelDocumentAI',
                payload: { requestId: state.active!.requestId },
              })}
            >
              Stop
            </button>
          ) : (
            <button type="button" className="conversation-send" disabled={sendDisabled} onClick={() => void send()}>
              {state.creating ? 'Starting…' : 'Send ⌘↵'}
            </button>
          )}
        </div>
      </div>
    </section>
  );
}
