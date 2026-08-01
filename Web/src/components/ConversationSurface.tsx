import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { bridge, loadStreamThread } from '../types/bridge';
import type { AIExchangeJSON, SourceScope, StreamThreadJSON } from '../types/models';

interface ConversationSurfaceProps {
  streamId: string;
  sourceScope: SourceScope;
  threadId?: string;
  anchorText: string;
  focusComposer: boolean;
  createThread: (query: string) => Promise<StreamThreadJSON>;
  hasDrifted: (anchorText: string) => boolean;
  onCollapse: () => void;
}

interface ActiveTurn {
  requestId: string;
  userInput: string;
  response: string;
  running: boolean;
  error?: string;
}

const copy = (text: string) => void navigator.clipboard?.writeText(text);

function Turn({ who, text }: { who: 'You' | 'AI'; text: string }) {
  return (
    <div className={`conversation-turn conversation-turn--${who === 'You' ? 'you' : 'ai'}`}>
      <span className="conversation-turn-label">{who}</span>
      <div className="conversation-turn-text">{text}</div>
      <button type="button" className="conversation-turn-copy" onClick={() => copy(text)}>Copy</button>
    </div>
  );
}

export function ConversationSurface({
  streamId,
  sourceScope,
  threadId,
  anchorText,
  focusComposer,
  createThread,
  hasDrifted,
  onCollapse,
}: ConversationSurfaceProps) {
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const collapseTimer = useRef<number>();
  const [thread, setThread] = useState<StreamThreadJSON | null>(null);
  const [exchanges, setExchanges] = useState<AIExchangeJSON[]>([]);
  const [composer, setComposer] = useState('');
  const [active, setActive] = useState<ActiveTurn | null>(null);
  const [loading, setLoading] = useState(Boolean(threadId));
  const [error, setError] = useState<string | null>(null);
  const [closing, setClosing] = useState(false);

  useEffect(() => {
    if (!threadId) return undefined;
    let live = true;
    void loadStreamThread(streamId, threadId)
      .then(({ thread: loaded }) => {
        if (!live) return;
        setThread(loaded);
        setExchanges(loaded.exchanges ?? []);
        setLoading(false);
      })
      .catch(() => {
        if (!live) return;
        setError('This conversation could not be loaded.');
        setLoading(false);
      });
    return () => { live = false; };
  }, [streamId, threadId]);

  useEffect(() => {
    if (!focusComposer) return;
    const frame = window.requestAnimationFrame(() => composerRef.current?.focus());
    return () => window.cancelAnimationFrame(frame);
  }, [focusComposer]);

  useEffect(() => bridge.onMessage((message) => {
    const payload = message.payload as Record<string, unknown> | undefined;
    if (!active || payload?.requestId !== active.requestId) return;
    if (message.type === 'documentAIChunk' && typeof payload.chunk === 'string') {
      setActive((current) => current?.requestId === active.requestId
        ? { ...current, response: current.response + payload.chunk }
        : current);
      return;
    }
    if (message.type === 'documentAIComplete') {
      const exchange = payload.exchange as AIExchangeJSON | undefined;
      if (exchange?.requestId === active.requestId) setExchanges((current) => [...current, exchange]);
      setActive(null);
      return;
    }
    if (message.type === 'documentAIError') {
      setActive((current) => current?.requestId === active.requestId
        ? {
          ...current,
          running: false,
          error: payload.errorCode === 'cancelled'
            ? 'Stopped.'
            : typeof payload.error === 'string' ? payload.error : 'AI request failed.',
        }
        : current);
    }
  }), [active]);

  useEffect(() => () => {
    if (collapseTimer.current !== undefined) window.clearTimeout(collapseTimer.current);
  }, []);

  const collapse = () => {
    if (closing) return;
    setClosing(true);
    collapseTimer.current = window.setTimeout(onCollapse, 150);
  };

  const send = async () => {
    const query = composer.trim();
    if (!query || active?.running) return;
    setError(null);
    let current = thread;
    if (!current) {
      try {
        current = await createThread(query);
        setThread(current);
      } catch {
        setError('This conversation could not be created.');
        return;
      }
    }
    const requestId = crypto.randomUUID();
    setComposer('');
    setActive({ requestId, userInput: query, response: '', running: true });
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
    } else if (event.key === 'Escape' && composer.length === 0) {
      event.preventDefault();
      collapse();
    }
  };

  const originalAnchorText = thread?.anchorText ?? anchorText;
  return (
    <section className={`conversation-surface ${closing ? 'conversation-surface--closing' : ''}`}>
      <button type="button" className="conversation-rail" aria-label="Collapse conversation" onClick={collapse} />
      <div className="conversation-content">
        {hasDrifted(originalAnchorText) && (
          <p className="conversation-drift-note">The passage has changed since this conversation started.</p>
        )}
        {loading && <p className="conversation-status">Loading conversation…</p>}
        {exchanges.map((exchange) => (
          <div className="conversation-exchange" key={exchange.requestId}>
            <Turn who="You" text={exchange.userInput} />
            <Turn who="AI" text={exchange.responseRaw} />
          </div>
        ))}
        {active && (
          <div className="conversation-exchange">
            <Turn who="You" text={active.userInput} />
            <Turn who="AI" text={active.response || active.error || 'Thinking…'} />
          </div>
        )}
        {error && <p className="conversation-error" role="alert">{error}</p>}
        <div className="conversation-composer-row">
          <textarea
            ref={composerRef}
            className="conversation-composer"
            value={composer}
            onChange={(event) => setComposer(event.target.value)}
            onKeyDown={handleComposerKeyDown}
            placeholder="Ask — sees this block, the Stream, and sources"
            rows={2}
            aria-label="Conversation message"
          />
          {active?.running ? (
            <button
              type="button"
              className="conversation-stop"
              onClick={() => bridge.send({
                type: 'cancelDocumentAI',
                payload: { requestId: active.requestId },
              })}
            >
              Stop
            </button>
          ) : (
            <button type="button" className="conversation-send" disabled={!composer.trim()} onClick={() => void send()}>
              Send ⌘↵
            </button>
          )}
        </div>
      </div>
    </section>
  );
}
