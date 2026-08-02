import { memo, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import {
  addStreamThreadAnchor,
  bridge,
  loadStreamThread,
  removeStreamThreadAnchor,
  type ConversationToolCall,
  type ConversationToolFailure,
} from '../types/bridge';
import type {
  AIExchangeJSON,
  SourceScope,
  StreamThreadAnchorJSON,
  StreamThreadJSON,
} from '../types/models';
import { parseThreadAISentFacts } from '../threads/context';

export interface ConversationActiveTurn {
  requestId: string;
  userInput: string;
  response: string;
  running: boolean;
  error?: string;
  sentContext?: unknown;
}

export interface ConversationLiveState {
  thread: StreamThreadJSON | null;
  exchanges: AIExchangeJSON[];
  composer: string;
  active: ConversationActiveTurn | null;
  loading: boolean;
  loadError: boolean;
  creating: boolean;
  keeping: boolean;
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
  keeping: false,
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
  primaryText: string;
  anchorStart: number;
  anchorEnd: number;
  streamMarkdown: string;
  contextOptions: ConversationContextOption[];
  focusComposer: boolean;
  ephemeral: boolean;
  profile?: 'research';
  state: ConversationLiveState;
  updateState: (key: string, updater: ConversationLiveStateUpdater) => void;
  createThread: (
    query: string,
    ephemeral: boolean,
    profile?: 'research',
  ) => Promise<StreamThreadJSON>;
  hasDrifted: (anchorText: string) => boolean;
  onPromote: (exchange: AIExchangeJSON) => void;
  onUpdateBlock: (exchange: AIExchangeJSON, toolCall: ConversationToolCall) => Promise<AIExchangeJSON>;
  onKeep: () => void;
  onCollapse: () => void;
}

export interface ConversationContextOption {
  kind: 'stream_quote' | 'pdf_quote';
  quote: string;
  from?: number;
  to?: number;
  sourceId?: string;
  sourceName?: string;
  sourceShortTitle?: string;
  highlightId?: string;
  page?: number;
  createdAt?: string;
  rects?: Array<{ page: number; x: number; y: number; w: number; h: number }>;
}

const copy = (text: string) => void navigator.clipboard?.writeText(text);

const toolFailureCopy: Record<ConversationToolFailure, string> = {
  passage_changed: "couldn't apply — passage changed",
  partial_anchor: "couldn't apply — select the whole passage",
  surface_closed: "couldn't apply — conversation closed",
  thread_mismatch: "couldn't apply — conversation changed",
  apply_error: "couldn't apply — edit failed",
};

function ThreadContextDisclosure({ value }: { value: unknown }) {
  const receipt = parseThreadAISentFacts(value);
  if (!receipt) return null;
  const retrieval = receipt.sourceContextMode === 'none'
    ? 'No source retrieval'
    : receipt.sourceContextMode === 'passthrough' ? 'All selected sources'
      : receipt.sourceContextMode === 'retrieved' ? 'Retrieved passages' : 'Source retrieval unavailable';
  return (
    <details className="conversation-receipt">
      <summary>What AI saw</summary>
      <div className="conversation-receipt-body">
        <p><span>Primary passage</span> {receipt.anchor.text || 'Unavailable'}</p>
        {receipt.streamDocument && (
          <p><span>Full stream document</span> · {receipt.streamDocument.charCount} chars</p>
        )}
        {receipt.pinned.map((pin, index) => (
          <p key={`${pin.kind}:${index}`}>
            <span>{pin.kind === 'pdf_quote' ? 'Pinned PDF' : 'Pinned Stream'}</span> {pin.quote}
          </p>
        ))}
        {receipt.profile === 'research' && <p><span>Research profile</span></p>}
        {receipt.updateBlock && (
          <>
            <p><span>Before edit</span> {receipt.updateBlock.before || 'Empty'}</p>
            <p><span>After edit</span> {receipt.updateBlock.after || 'Empty'}</p>
          </>
        )}
        <p>
          <span>Sources</span> {retrieval}
          {receipt.sources.length > 0
            ? ` · ${receipt.sources.map((source) => `${source.shortTitle}${source.page ? ` p.${source.page}` : ''}`).join(', ')}`
            : ''}
        </p>
        <p><span>Prior turns</span> {receipt.turns.includedRequestIds.length} of {receipt.turns.totalAtSend}</p>
      </div>
    </details>
  );
}

const Turn = memo(function Turn({
  who,
  text,
  receipt,
  exchange,
  onPromote,
}: {
  who: 'You' | 'AI';
  text: string;
  receipt?: unknown;
  exchange?: AIExchangeJSON;
  onPromote?: (exchange: AIExchangeJSON) => void;
}) {
  const facts = parseThreadAISentFacts(receipt);
  const update = facts?.updateBlock;
  const visibleText = update && update.applied !== true
    ? update.after || 'Clear this block.'
    : text;
  return (
    <div className={`conversation-turn conversation-turn--${who === 'You' ? 'you' : 'ai'}`}>
      <span className="conversation-turn-label">{who}</span>
      <div className="conversation-turn-text">{visibleText}</div>
      {update?.applied === true && (
        <p className="conversation-tool-note">AI edited this block · ⌘Z undoes it</p>
      )}
      {update && update.applied === undefined && (
        <p className="conversation-tool-note">Proposed edit (not applied)</p>
      )}
      {update?.applied === false && (
        <p className="conversation-tool-note">{toolFailureCopy[update.failure!]}</p>
      )}
      {who === 'AI' && <ThreadContextDisclosure value={receipt} />}
      <div className="conversation-turn-controls">
        {exchange && onPromote && (
          <button type="button" onClick={() => onPromote(exchange)}>↑ Add to Stream</button>
        )}
        <button type="button" onClick={() => copy(visibleText)}>Copy</button>
      </div>
    </div>
  );
});

export function ConversationSurface({
  conversationKey,
  streamId,
  sourceScope,
  threadId,
  anchorText,
  primaryText,
  anchorStart,
  anchorEnd,
  streamMarkdown,
  contextOptions,
  focusComposer,
  ephemeral,
  profile,
  state,
  updateState,
  createThread,
  hasDrifted,
  onPromote,
  onUpdateBlock,
  onKeep,
  onCollapse,
}: ConversationSurfaceProps) {
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const [showContextMenu, setShowContextMenu] = useState(false);
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
    if (focusComposer) composerRef.current?.focus();
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
    if (message.type === 'threadAIContext') {
      updateState(conversationKey, (current) => current.active?.requestId === requestId
        ? { ...current, active: { ...current.active, sentContext: payload.sentContext } }
        : current);
      return;
    }
    if (message.type === 'documentAIComplete') {
      activeRequestId.current = null;
      const exchange = payload.exchange as AIExchangeJSON | undefined;
      const toolCall = payload.toolCall as ConversationToolCall | null | undefined;
      updateState(conversationKey, (current) => ({
        ...current,
        exchanges: exchange?.requestId === requestId
          ? [...current.exchanges, exchange]
          : current.exchanges,
        active: null,
      }));
      void (async () => {
        if (exchange?.requestId !== requestId || toolCall?.name !== 'update_block') return;
        const completed = await onUpdateBlock(exchange, toolCall).catch(() => exchange);
        updateState(conversationKey, (current) => ({
          ...current,
          exchanges: current.exchanges.map((candidate) => (
            candidate.requestId === requestId ? completed : candidate
          )),
        }));
      })();
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
  }), [conversationKey, onUpdateBlock, updateState]);

  const send = async () => {
    const snapshot = stateRef.current;
    const query = snapshot.composer.trim();
    if (!query || snapshot.active?.running || snapshot.loading || snapshot.creating) return;
    if (threadId && !snapshot.thread) return;
    let current = snapshot.thread;
    if (!current && !threadId) {
      updateState(conversationKey, (value) => ({ ...value, creating: true, error: null }));
      try {
        current = await createThread(query, ephemeral, profile);
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
    const researchProfile = current.profile === 'research' || profile === 'research';
    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId,
        threadId: current.threadId,
        query,
        context: primaryText,
        anchorStart,
        anchorEnd,
        streamMarkdown,
        imageURLs: [],
        sourceScope,
        verb: 'develop',
        profile: researchProfile ? 'research' : undefined,
      },
    });
  };

  const handleComposerKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
      event.preventDefault();
      void send();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      onCollapse();
    }
  };

  const retryLoad = () => updateState(conversationKey, (current) => ({
    ...current,
    loading: true,
    loadError: false,
  }));
  const addContext = async (option: ConversationContextOption) => {
    const thread = stateRef.current.thread;
    if (!thread) return;
    setShowContextMenu(false);
    try {
      const { anchor } = await addStreamThreadAnchor({
        streamId,
        threadId: thread.threadId,
        anchor: {
          anchorId: crypto.randomUUID(),
          kind: option.kind,
          quote: option.quote,
          createdAt: option.createdAt ?? new Date().toISOString(),
          ...(option.kind === 'stream_quote'
            ? { anchorSpanId: `pm:${option.from}:${option.to}` }
            : {
              sourceId: option.sourceId,
              highlightId: option.highlightId,
              rects: option.rects,
            }),
        },
      });
      updateState(conversationKey, (current) => current.thread ? {
        ...current,
        thread: { ...current.thread, anchors: [...(current.thread.anchors ?? []), anchor] },
      } : current);
    } catch {
      updateState(conversationKey, (current) => ({ ...current, error: 'Context could not be added.' }));
    }
  };
  const removeContext = async (anchor: StreamThreadAnchorJSON) => {
    const thread = stateRef.current.thread;
    if (!thread) return;
    try {
      const { removed } = await removeStreamThreadAnchor({
        streamId,
        threadId: thread.threadId,
        anchorId: anchor.anchorId,
      });
      if (!removed) return;
      updateState(conversationKey, (current) => current.thread ? {
        ...current,
        thread: {
          ...current.thread,
          anchors: (current.thread.anchors ?? []).filter((item) => item.anchorId !== anchor.anchorId),
        },
      } : current);
    } catch {
      updateState(conversationKey, (current) => ({ ...current, error: 'Context could not be removed.' }));
    }
  };
  const originalAnchorText = state.thread?.anchorText ?? anchorText;
  const sendDisabled = !state.composer.trim() || state.loading || state.creating
    || Boolean(threadId && !state.thread);
  return (
    <section className={`conversation-surface ${state.closing ? 'conversation-surface--closing' : ''}`}>
      <button
        type="button"
        className="conversation-rail"
        aria-label="Collapse conversation"
        title="Collapse conversation"
        onClick={onCollapse}
      />
      <div className="conversation-content">
        <div className="conversation-header">
          {ephemeral && (
            <button
              type="button"
              className="conversation-keep"
              disabled={state.keeping || state.creating}
              onClick={onKeep}
            >
              Keep
            </button>
          )}
          <button
            type="button"
            className="conversation-close"
            aria-label="Close conversation"
            title="Close conversation"
            onClick={onCollapse}
          >
            ×
          </button>
        </div>
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
            <Turn
              who="AI"
              text={exchange.responseRaw}
              receipt={exchange.sourceManifest}
              exchange={exchange}
              onPromote={onPromote}
            />
          </div>
        ))}
        {state.active && (
          <div className="conversation-exchange">
            <Turn who="You" text={state.active.userInput} />
            <Turn
              who="AI"
              text={state.active.response || state.active.error || 'Thinking…'}
              receipt={state.active.sentContext}
            />
          </div>
        )}
        {state.error && <p className="conversation-error" role="alert">{state.error}</p>}
        {(state.thread?.anchors?.length ?? 0) > 0 && (
          <div className="conversation-pins" aria-label="Pinned context">
            {state.thread!.anchors!.map((anchor) => (
              <span className="conversation-pin" key={anchor.anchorId}>
                {anchor.kind === 'pdf_quote'
                  ? `${anchor.sourceShortTitle ?? anchor.sourceName ?? 'PDF'}${anchor.sourcePage ? ` p.${anchor.sourcePage}` : ''}`
                  : anchor.quote}
                <button type="button" aria-label="Remove pinned context" onClick={() => void removeContext(anchor)}>×</button>
              </span>
            ))}
          </div>
        )}
        <div className="conversation-composer-row">
          <div className="conversation-context-picker">
            <button
              type="button"
              className="conversation-context-button"
              disabled={!state.thread || contextOptions.length === 0}
              onClick={() => setShowContextMenu((visible) => !visible)}
            >
              + context
            </button>
            {showContextMenu && (
              <div className="conversation-context-menu">
                {contextOptions.map((option) => (
                  <button
                    type="button"
                    key={`${option.kind}:${option.highlightId ?? `${option.from}:${option.to}`}`}
                    onClick={() => void addContext(option)}
                  >
                    {option.kind === 'pdf_quote' ? 'PDF selection' : 'Stream selection'}
                  </button>
                ))}
              </div>
            )}
          </div>
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
            rows={1}
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
