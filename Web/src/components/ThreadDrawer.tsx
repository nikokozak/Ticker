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
  deleteStreamThread,
  listStreamThreads,
  loadStreamThread,
  removeStreamThreadAnchor,
  saveStreamThread,
  setThreadExchangeDisposition,
} from '../types/bridge';
import type {
  AIExchangeJSON,
  SourceScope,
  StreamThreadAnchorJSON,
  StreamThreadJSON,
} from '../types/models';
import { createRichTextEditor, type RichTextEditor } from '../richtext/editor';
import { parseMarkdown } from '../richtext/markdown';
import { focusAtEnd } from '../richtext/operations';
import { tickerSchema } from '../richtext/schema';
import {
  activeFormats,
  toggleBlockquote,
  toggleBold,
  toggleBulletList,
  toggleItalic,
  toggleUnderline,
} from '../richtext/commands';
import type { Command } from 'prosemirror-state';
import { ThreadDraftSession, type ThreadSaveState } from '../threads/session';
import {
  manifestCitations,
  parseThreadAISentFacts,
  type ThreadAISentFacts,
} from '../threads/context';
import { useToastStore } from '../store/toastStore';
import { buildCitationURL, swapCitationMarkers } from '../utils/citationMarkers';
import { Modal } from './Modal';
import { XIcon } from './icons';

export type SidenotePromotionTarget =
  | { kind: 'afterAnchor'; anchorSpanId: string }
  | { kind: 'replaceAnchor'; anchorSpanId: string }
  | { kind: 'cursor' }
  | { kind: 'end' };

export interface SidenotePromotionRequest {
  text: string;
  threadId: string;
  target: SidenotePromotionTarget;
}

export interface ThreadDrawerHandle {
  flush: () => Promise<boolean>;
  leave: () => Promise<boolean>;
  cancelAI: () => void;
  close: () => Promise<boolean>;
  openThread: (threadId: string) => Promise<boolean>;
  showThread: (thread: StreamThreadJSON) => Promise<boolean>;
  addAnchor: (anchor: StreamThreadAnchorJSON) => Promise<boolean>;
}

interface ThreadDrawerProps {
  streamId: string;
  isOpen: boolean;
  onRequestClose: () => void;
  onAfterClose?: () => void;
  onLocateAnchor?: (anchor: StreamThreadAnchorJSON) => boolean;
  onActiveThreadChange?: (thread: StreamThreadJSON | null) => void;
  sourceScope?: SourceScope;
  onBeginAI?: () => boolean;
  onEndAI?: () => void;
  onOpenPDFDestination?: (url: string) => void;
  onPromote?: (request: SidenotePromotionRequest) => Promise<boolean>;
  onThreadsChange?: (threads: StreamThreadJSON[]) => void;
  onSidenoteUpdated?: (thread: StreamThreadJSON) => void;
  onSidenoteDeleted?: (threadId: string) => Promise<void> | void;
  streamSaveErrorThreadId?: string | null;
  onRetryStreamSave?: () => void;
}

interface PendingSidenoteAI {
  requestId: string;
  prompt: string;
  response: string;
  sentContext?: ThreadAISentFacts;
  exchange?: AIExchangeJSON;
  error?: string;
  localApplied?: boolean;
}

const sidenoteMarkdown = MarkdownIt('commonmark', {
  html: false,
  breaks: false,
  linkify: false,
  typographer: false,
});
sidenoteMarkdown.renderer.rules.image = (tokens, index) => (
  sidenoteMarkdown.utils.escapeHtml(tokens[index].content || 'Image')
);

function trimTitle(value: string, fallback = 'Untitled Sidenote'): string {
  const oneLine = value.trim().replace(/\s+/g, ' ');
  if (!oneLine) return fallback;
  return oneLine.length > 60 ? `${oneLine.slice(0, 59)}…` : oneLine;
}

function shortQuote(value: string): string {
  const oneLine = value.trim().replace(/\s+/g, ' ');
  return oneLine.length > 28 ? `${oneLine.slice(0, 27)}…` : oneLine || 'quote';
}

function anchorLabel(anchor: StreamThreadAnchorJSON): string {
  if (anchor.kind !== 'pdf_quote') return 'Stream';
  const source = anchor.sourceShortTitle || anchor.sourceName || 'PDF';
  return anchor.sourcePage ? `${source} · p. ${anchor.sourcePage}` : source;
}

function legacyAnchor(thread: StreamThreadJSON): StreamThreadAnchorJSON | null {
  if (!thread.anchorText && !thread.anchorSpanId && !thread.highlightId) return null;
  return {
    anchorId: `${thread.threadId}:legacy`,
    threadId: thread.threadId,
    kind: thread.sourceId && thread.highlightId ? 'pdf_quote' : 'stream_quote',
    quote: thread.anchorText,
    anchorSpanId: thread.anchorSpanId,
    sourceId: thread.sourceId,
    sourceName: thread.sourceName,
    sourceShortTitle: thread.sourceShortTitle,
    highlightId: thread.highlightId,
    sourcePage: thread.sourcePage,
    createdAt: thread.createdAt,
  };
}

function evidenceNode(anchor: StreamThreadAnchorJSON) {
  return tickerSchema.nodes.evidence.create({
    anchorId: anchor.anchorId,
    kind: anchor.kind,
    quote: anchor.quote ?? '',
    label: anchorLabel(anchor),
  });
}

export function buildSidenoteDocumentJSON(
  anchors: StreamThreadAnchorJSON[],
  writing = '',
): string {
  const blocks = anchors.filter((anchor) => anchor.kind !== 'placement').map(evidenceNode);
  if (writing.trim()) parseMarkdown(writing).forEach((node) => blocks.push(node));
  if (blocks.every((node) => node.type === tickerSchema.nodes.evidence)) {
    blocks.push(tickerSchema.nodes.paragraph.create());
  }
  return JSON.stringify(tickerSchema.nodes.doc.create(null, blocks).toJSON());
}

function hydrateThread(thread: StreamThreadJSON): StreamThreadJSON {
  const supplied = thread.anchors?.filter((anchor) => anchor.kind !== 'placement') ?? [];
  const fallback = supplied.length ? [] : [legacyAnchor(thread)].filter(Boolean) as StreamThreadAnchorJSON[];
  const anchors = [...supplied, ...fallback];
  if (!thread.docJSON || thread.docFormatVersion !== 1) {
    return {
      ...thread,
      anchors,
      docJSON: buildSidenoteDocumentJSON(anchors, thread.workingText),
      docFormatVersion: 1,
    };
  }

  try {
    const stored = tickerSchema.nodeFromJSON(JSON.parse(thread.docJSON));
    const liveIds = new Set(anchors.map((anchor) => anchor.anchorId));
    const present = new Set<string>();
    const blocks = [] as ReturnType<typeof evidenceNode>[];
    stored.forEach((node) => {
      if (node.type === tickerSchema.nodes.evidence) {
        const id = String(node.attrs.anchorId);
        if (!liveIds.has(id)) return;
        present.add(id);
      }
      blocks.push(node);
    });
    const missing = anchors.filter((anchor) => !present.has(anchor.anchorId)).map(evidenceNode);
    const merged = [...missing, ...blocks];
    if (merged.every((node) => node.type === tickerSchema.nodes.evidence)) {
      merged.push(tickerSchema.nodes.paragraph.create());
    }
    return {
      ...thread,
      anchors,
      docJSON: JSON.stringify(tickerSchema.nodes.doc.create(null, merged).toJSON()),
      docFormatVersion: 1,
    };
  } catch {
    return {
      ...thread,
      anchors,
      docJSON: buildSidenoteDocumentJSON(anchors, thread.workingText),
      docFormatVersion: 1,
    };
  }
}

function displayTitle(thread: StreamThreadJSON): string {
  return trimTitle(thread.title, trimTitle(thread.anchorText));
}

function sourceLabels(thread: StreamThreadJSON): string[] {
  const labels = (thread.anchors ?? []).flatMap((anchor) => {
    if (anchor.kind === 'placement') return [];
    if (anchor.kind === 'stream_quote') return ['Stream'];
    return [anchor.sourceShortTitle || anchor.sourceName || 'PDF'];
  });
  return [...new Set(labels)];
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

function sourceURL(source: ThreadAISentFacts['sources'][number]): string {
  if (source.page && source.chunkId) {
    return buildCitationURL({ sourceId: source.sourceId, chunkId: source.chunkId, page: source.page });
  }
  return `ticker-pdf://${source.sourceId}?page=1`;
}

function anchorURL(anchor: StreamThreadAnchorJSON): string | null {
  if (!anchor.sourceId) return null;
  const params = new URLSearchParams();
  if (anchor.highlightId) params.set('highlight', anchor.highlightId);
  params.set('page', String(anchor.sourcePage ?? 1));
  return `ticker-pdf://${anchor.sourceId}?${params}`;
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
  return (
    <details className="sidenote-ai-context">
      <summary>What AI saw</summary>
      <div>
        {facts.anchor.text && <blockquote>{facts.anchor.text}</blockquote>}
        {facts.note.sent && <p>{facts.note.text}</p>}
        {facts.sources.map((source) => (
          <button
            key={`${source.sourceId}:${source.chunkId ?? 'whole'}:${source.page ?? 0}`}
            type="button"
            onClick={() => onOpenPDFDestination?.(sourceURL(source))}
          >
            {source.shortTitle}{source.page ? ` · p. ${source.page}` : ''}
          </button>
        ))}
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
  const html = useMemo(() => (
    sidenoteMarkdown.render(swapCitationMarkers(markdown, manifestCitations(sourceManifest)))
  ), [markdown, sourceManifest]);
  return (
    <div
      className="sidenote-ai-response"
      onClick={(event) => {
        const link = (event.target as HTMLElement).closest('a');
        if (!link) return;
        event.preventDefault();
        const href = link.getAttribute('href') ?? '';
        if (href.startsWith('ticker-pdf://')) onOpenPDFDestination?.(href);
        else if (/^https?:\/\//i.test(href)) bridge.send({ type: 'openExternalURL', payload: { url: href } });
      }}
      // markdown-it runs with HTML and images disabled above.
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

export const ThreadDrawer = forwardRef<ThreadDrawerHandle, ThreadDrawerProps>(function ThreadDrawer({
  streamId,
  isOpen,
  onRequestClose,
  onAfterClose,
  onLocateAnchor,
  onActiveThreadChange,
  sourceScope = 'auto',
  onBeginAI,
  onEndAI,
  onOpenPDFDestination,
  onPromote,
  onThreadsChange,
  onSidenoteUpdated,
  onSidenoteDeleted,
  streamSaveErrorThreadId,
  onRetryStreamSave,
}, ref) {
  const editorHostRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLElement>(null);
  const documentScrollRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<RichTextEditor | null>(null);
  const sessionRef = useRef<ThreadDraftSession | null>(null);
  const activeThreadRef = useRef<StreamThreadJSON | null>(null);
  const anchorsRef = useRef<StreamThreadAnchorJSON[]>([]);
  const aiStartGenerationRef = useRef(0);
  const activeRequestIdRef = useRef<string | null>(null);
  const activePromptRef = useRef<string | null>(null);
  const aiClaimedRef = useRef(false);
  const focusNewDraftRef = useRef(false);
  const notifiedTitleRef = useRef('');
  const [threads, setThreads] = useState<StreamThreadJSON[]>([]);
  const [activeThread, setActiveThread] = useState<StreamThreadJSON | null>(null);
  const [exchanges, setExchanges] = useState<AIExchangeJSON[]>([]);
  const [prompt, setPrompt] = useState('');
  const [pendingAI, setPendingAI] = useState<PendingSidenoteAI | null>(null);
  const [preparingAI, setPreparingAI] = useState(false);
  const [saveState, setSaveState] = useState<ThreadSaveState>('saved');
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [, setEditorVersion] = useState(0);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState(false);
  const addToast = useToastStore((state) => state.addToast);

  const syncDraftFromEditor = useCallback(() => {
    const current = activeThreadRef.current;
    const currentEditor = editorRef.current;
    if (!current || !currentEditor) return;
    let firstLine = '';
    currentEditor.view.state.doc.forEach((node) => {
      if (!firstLine && node.type !== tickerSchema.nodes.evidence) firstLine = node.textContent.trim();
    });
    const fallback = anchorsRef.current.find((anchor) => anchor.quote)?.quote ?? current.anchorText;
    const next = {
      title: trimTitle(firstLine, trimTitle(fallback)),
      workingText: currentEditor.getMarkdownProjection(),
      docJSON: currentEditor.getDocumentJSON(),
      docFormatVersion: 1,
    };
    sessionRef.current?.update(next);
    const updated = { ...current, ...next };
    activeThreadRef.current = updated;
    setActiveThread(updated);
    if (updated.title !== notifiedTitleRef.current) {
      notifiedTitleRef.current = updated.title;
      onSidenoteUpdated?.(updated);
    }
    setEditorVersion((value) => value + 1);
  }, [onSidenoteUpdated]);

  const openEvidence = useCallback((anchorId: string) => {
    const anchor = anchorsRef.current.find((candidate) => candidate.anchorId === anchorId);
    if (!anchor) return;
    const url = anchorURL(anchor);
    if (url) onOpenPDFDestination?.(url);
    else if (!onLocateAnchor?.(anchor)) addToast('This Stream quote has changed or was removed.', 'warning');
  }, [addToast, onLocateAnchor, onOpenPDFDestination]);

  const removeEvidence = useCallback(async (anchorId: string) => {
    const current = activeThreadRef.current;
    const anchor = anchorsRef.current.find((candidate) => candidate.anchorId === anchorId);
    if (!current || !anchor) return false;
    if (anchorsRef.current.filter((candidate) => candidate.kind !== 'placement').length <= 1) {
      addToast('A Sidenote must keep at least one quote.', 'info');
      return false;
    }
    try {
      await removeStreamThreadAnchor({ streamId, threadId: current.threadId, anchorId });
      anchorsRef.current = anchorsRef.current.filter((candidate) => candidate.anchorId !== anchorId);
      const updated = { ...activeThreadRef.current!, anchors: anchorsRef.current };
      activeThreadRef.current = updated;
      setActiveThread(updated);
      onSidenoteUpdated?.(updated);
      if (anchor.highlightId) bridge.send({
        type: 'deletePdfHighlight', payload: { streamId, highlightId: anchor.highlightId },
      });
      return true;
    } catch {
      addToast('The quote could not be removed.', 'error');
      return false;
    }
  }, [addToast, onSidenoteUpdated, streamId]);

  const installThread = useCallback((raw: StreamThreadJSON) => {
    const thread = hydrateThread(raw);
    sessionRef.current?.discard();
    activeThreadRef.current = thread;
    notifiedTitleRef.current = thread.title;
    anchorsRef.current = thread.anchors ?? [];
    setActiveThread(thread);
    onActiveThreadChange?.(thread);
    const loadedExchanges = thread.exchanges ?? [];
    setExchanges(loadedExchanges);
    const pending = [...loadedExchanges].reverse().find((exchange) => exchange.threadDisposition === 'pending');
    setPendingAI(pending ? {
      requestId: pending.requestId,
      prompt: pending.userInput,
      response: pending.responseRaw,
      sentContext: parseThreadAISentFacts(pending.sourceManifest) ?? undefined,
      exchange: pending,
    } : null);
    setPrompt('');
    activePromptRef.current = null;
    setSaveState('saved');
    sessionRef.current = new ThreadDraftSession({
      thread,
      save: saveStreamThread,
      onSaveStateChange: setSaveState,
    });
  }, [onActiveThreadChange]);

  useEffect(() => {
    if (!activeThread || !editorHostRef.current) return undefined;
    editorHostRef.current.replaceChildren();
    const created = createRichTextEditor({
      parent: editorHostRef.current,
      docJSON: activeThread.docJSON!,
      allowEvidence: true,
      onChange: syncDraftFromEditor,
      onUpdate: () => setEditorVersion((value) => value + 1),
      onOpenLink: (href) => {
        if (href.startsWith('ticker-pdf://')) onOpenPDFDestination?.(href);
        else bridge.send({ type: 'openExternalURL', payload: { url: href } });
      },
      onOpenEvidence: openEvidence,
      onRemoveEvidence: removeEvidence,
    });
    editorRef.current = created;
    if (focusNewDraftRef.current) {
      focusAtEnd(created.view);
    } else {
      documentScrollRef.current?.scrollTo?.({ top: 0 });
      window.requestAnimationFrame(() => panelRef.current?.focus({ preventScroll: true }));
    }
    focusNewDraftRef.current = false;
    setEditorVersion((value) => value + 1);
    return () => {
      if (editorRef.current === created) editorRef.current = null;
      created.destroy();
    };
  }, [activeThread?.threadId, onOpenPDFDestination, openEvidence, removeEvidence, syncDraftFromEditor]);

  const refreshList = useCallback(async () => {
    setLoading(true);
    setLoadError(false);
    try {
      const result = await listStreamThreads(streamId);
      setThreads(result.threads);
      onThreadsChange?.(result.threads);
    } catch {
      setLoadError(true);
    } finally {
      setLoading(false);
    }
  }, [onThreadsChange, streamId]);

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
    if (requestId) setPendingAI(null);
    releaseAI();
  }, [releaseAI]);

  const clearActive = useCallback(() => {
    sessionRef.current?.discard();
    sessionRef.current = null;
    activeThreadRef.current = null;
    anchorsRef.current = [];
    setActiveThread(null);
    onActiveThreadChange?.(null);
    setSaveState('saved');
  }, [onActiveThreadChange]);

  const deleteStored = useCallback(async (current: StreamThreadJSON, announce: boolean) => {
    try {
      const result = await deleteStreamThread({ streamId, threadId: current.threadId });
      result.highlightIds.forEach((highlightId) => bridge.send({
        type: 'deletePdfHighlight', payload: { streamId, highlightId },
      }));
      await onSidenoteDeleted?.(current.threadId);
      clearActive();
      await refreshList();
      if (announce) addToast('Sidenote deleted.', 'success');
      return true;
    } catch {
      addToast('The Sidenote could not be deleted.', 'error');
      return false;
    }
  }, [addToast, clearActive, onSidenoteDeleted, refreshList, streamId]);

  const leave = useCallback(async () => {
    cancelAI();
    const current = activeThreadRef.current;
    if (!current) return true;
    let hasWriting = false;
    editorRef.current?.view.state.doc.forEach((node) => {
      if (node.type !== tickerSchema.nodes.evidence && node.textContent.trim()) hasWriting = true;
    });
    const quoteCount = anchorsRef.current.filter((anchor) => anchor.kind !== 'placement').length;
    if (!hasWriting && exchanges.length === 0 && quoteCount <= 1) {
      return deleteStored(current, false);
    }
    return flush();
  }, [cancelAI, deleteStored, exchanges.length, flush]);

  const close = useCallback(async () => {
    if (!await leave()) {
      addToast('Your Sidenote could not be saved, so it stayed open.', 'error');
      return false;
    }
    clearActive();
    onRequestClose();
    window.setTimeout(() => onAfterClose?.(), 0);
    return true;
  }, [addToast, clearActive, leave, onAfterClose, onRequestClose]);

  const openThread = useCallback(async (threadId: string) => {
    if (activeThreadRef.current?.threadId === threadId) return true;
    cancelAI();
    if (!await flush()) return false;
    setLoading(true);
    try {
      focusNewDraftRef.current = false;
      installThread((await loadStreamThread(streamId, threadId)).thread);
      return true;
    } catch {
      addToast('This Sidenote could not be opened.', 'error');
      return false;
    } finally {
      setLoading(false);
    }
  }, [addToast, cancelAI, flush, installThread, streamId]);

  const showThread = useCallback(async (thread: StreamThreadJSON) => {
    if (activeThreadRef.current?.threadId === thread.threadId) return true;
    cancelAI();
    if (!await flush()) return false;
    focusNewDraftRef.current = true;
    installThread(thread);
    return true;
  }, [cancelAI, flush, installThread]);

  const addAnchor = useCallback(async (anchor: StreamThreadAnchorJSON) => {
    const current = activeThreadRef.current;
    if (!current || current.threadId !== anchor.threadId || !editorRef.current) return false;
    anchorsRef.current = [...anchorsRef.current, anchor];
    const updated = { ...current, anchors: anchorsRef.current };
    activeThreadRef.current = updated;
    setActiveThread(updated);
    onSidenoteUpdated?.(updated);
    if (anchor.kind !== 'placement') {
      editorRef.current.appendEvidence({
        anchorId: anchor.anchorId,
        kind: anchor.kind,
        quote: anchor.quote ?? '',
        label: anchorLabel(anchor),
      });
    }
    return flush();
  }, [flush, onSidenoteUpdated]);

  useImperativeHandle(ref, () => ({
    flush,
    leave,
    cancelAI,
    close,
    openThread,
    showThread,
    addAnchor,
  }), [addAnchor, cancelAI, close, flush, leave, openThread, showThread]);

  useEffect(() => {
    if (isOpen && !activeThreadRef.current) void refreshList();
  }, [isOpen, refreshList]);

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
      setPendingAI((pending) => pending?.requestId === requestId
        ? { ...pending, response: pending.response + String(payload.chunk) }
        : pending);
      return;
    }
    if (message.type === 'documentAIComplete') {
      const exchange = payload.exchange as AIExchangeJSON | undefined;
      activeRequestIdRef.current = null;
      releaseAI();
      if (!exchange || exchange.requestId !== requestId || exchange.threadId !== activeThreadRef.current?.threadId) {
        setPendingAI((pending) => pending && { ...pending, error: 'The saved AI answer was invalid.' });
        return;
      }
      activePromptRef.current = null;
      setExchanges((current) => current.some((item) => item.requestId === exchange.requestId)
        ? current
        : [...current, exchange]);
      setPendingAI((pending) => ({
        requestId,
        prompt: exchange.userInput,
        response: exchange.responseRaw,
        sentContext: pending?.sentContext ?? parseThreadAISentFacts(exchange.sourceManifest) ?? undefined,
        exchange,
      }));
      return;
    }
    if (message.type === 'documentAIError') {
      activeRequestIdRef.current = null;
      releaseAI();
      setPendingAI((pending) => pending && {
        ...pending,
        error: typeof payload.error === 'string' ? payload.error : 'AI request failed.',
      });
    }
  }), [releaseAI]);

  const showList = async () => {
    cancelAI();
    if (!await flush()) return;
    clearActive();
    await refreshList();
  };

  const sendPrompt = async () => {
    const thread = activeThreadRef.current;
    const query = prompt.trim();
    if (!thread || !query || pendingAI || preparingAI) return;
    if (saveState !== 'saved') {
      addToast('Wait until the Sidenote is saved.', 'info');
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
        addToast('Save the Sidenote before asking AI.', 'error');
      }
      return;
    }
    if (generation !== aiStartGenerationRef.current || activeThreadRef.current?.threadId !== thread.threadId) return;
    const requestId = crypto.randomUUID();
    activeRequestIdRef.current = requestId;
    activePromptRef.current = query;
    setPendingAI({ requestId, prompt: query, response: '' });
    setPrompt('');
    setPreparingAI(false);
    bridge.send({
      type: 'thinkDocument',
      payload: { requestId, streamId, threadId: thread.threadId, query, sourceScope, imageURLs: [] },
    });
  };

  const keepAnswer = async () => {
    if (!pendingAI?.exchange || !editorRef.current) return;
    if (!pendingAI.localApplied) {
      editorRef.current.appendMarkdown(renderedExchangeMarkdown(pendingAI.exchange));
      setPendingAI({ ...pendingAI, localApplied: true });
    }
    if (!await flush()) {
      addToast('The answer is still here, but the Sidenote could not be saved.', 'error');
      return;
    }
    try {
      await setThreadExchangeDisposition({
        streamId,
        threadId: pendingAI.exchange.threadId!,
        requestId: pendingAI.exchange.requestId,
        disposition: 'kept',
      });
      setExchanges((current) => current.map((exchange) => exchange.requestId === pendingAI.exchange!.requestId
        ? { ...exchange, threadDisposition: 'kept' }
        : exchange));
      setPendingAI(null);
    } catch {
      setPendingAI({ ...pendingAI, localApplied: true });
      addToast('The answer was saved, but its history state could not be updated.', 'error');
    }
  };

  const discardAnswer = async () => {
    if (!pendingAI?.exchange) return;
    try {
      await setThreadExchangeDisposition({
        streamId,
        threadId: pendingAI.exchange.threadId!,
        requestId: pendingAI.exchange.requestId,
        disposition: 'discarded',
      });
      setExchanges((current) => current.map((exchange) => exchange.requestId === pendingAI.exchange!.requestId
        ? { ...exchange, threadDisposition: 'discarded' }
        : exchange));
      setPendingAI(null);
    } catch {
      addToast('The answer could not be discarded.', 'error');
    }
  };

  const reloadStored = () => {
    const stored = sessionRef.current?.reloadStored();
    if (stored) installThread(stored);
  };
  const keepLocal = async () => {
    if (await sessionRef.current?.keepLocal()) addToast('Your Sidenote was saved.', 'success');
  };

  const promote = async (target: SidenotePromotionTarget) => {
    const current = activeThreadRef.current;
    const text = editorRef.current?.getSelectionOrBlockMarkdown().trim();
    if (!current || !text || !onPromote) return;
    if (!await flush()) {
      addToast('Save the Sidenote before adding from it.', 'error');
      return;
    }
    if (await onPromote({ text, threadId: current.threadId, target })) {
      addToast('Added to the Stream.', 'success');
    }
  };

  const deleteActive = async () => {
    const current = activeThreadRef.current;
    if (!current) return;
    cancelAI();
    if (await deleteStored(current, true)) {
      setDeleteConfirm(false);
    }
  };

  const currentEditor = editorRef.current;
  const formats = currentEditor ? activeFormats(currentEditor.view.state) : null;
  const promotionText = currentEditor?.getSelectionOrBlockMarkdown().trim() ?? '';
  let hasWriting = false;
  currentEditor?.view.state.doc.forEach((node) => {
    if (node.type !== tickerSchema.nodes.evidence && node.textContent.trim()) hasWriting = true;
  });
  const quoteAnchors = activeThread?.anchors?.filter((anchor) => anchor.kind !== 'placement') ?? [];
  const streamAnchors = quoteAnchors.filter((anchor) => anchor.kind === 'stream_quote' && anchor.anchorSpanId);
  const placementAnchors = activeThread?.anchors?.filter((anchor) => anchor.kind === 'placement' && anchor.anchorSpanId) ?? [];
  const primaryStreamAnchor = streamAnchors[0];
  const primaryAnchorSpanId = primaryStreamAnchor?.anchorSpanId;
  const history = exchanges.filter((exchange) => exchange.threadDisposition !== 'pending');

  if (!isOpen) return null;
  return (
    <aside
      ref={panelRef}
      className="sidenote-panel"
      aria-label="Sidenotes"
      tabIndex={-1}
      onKeyDown={(event) => {
        if (event.key !== 'Escape' || historyOpen || deleteConfirm) return;
        event.preventDefault();
        event.stopPropagation();
        void close();
      }}
    >
      <header className="sidenote-header">
        {activeThread ? (
          <button type="button" className="sidenote-back" onClick={() => { void showList(); }}>
            ← Sidenotes
          </button>
        ) : <h2>Sidenotes</h2>}
        <div className="sidenote-header-actions">
          {activeThread && (
            <details className="sidenote-menu">
              <summary aria-label="More Sidenote actions">•••</summary>
              <div>
                <button type="button" onClick={() => setHistoryOpen(true)}>
                  AI history{history.length ? ` · ${history.length}` : ''}
                </button>
                <button type="button" className="sidenote-delete" onClick={() => setDeleteConfirm(true)}>
                  Delete Sidenote
                </button>
              </div>
            </details>
          )}
          <button type="button" className="sidenote-close" aria-label="Close Sidenotes" onClick={() => { void close(); }}>
            <XIcon size={14} />
          </button>
        </div>
      </header>

      {activeThread ? (
        <div className="sidenote-detail">
          <div ref={documentScrollRef} className="sidenote-document-scroll">
            <div className="sidenote-editor-wrap">
              <div ref={editorHostRef} className="sidenote-editor" />
              {currentEditor && !hasWriting && (
                <span className="sidenote-placeholder">What are you trying to work out?</span>
              )}
            </div>

            {saveState === 'conflict' && (
              <div className="sidenote-warning" role="alert">
                <p>This Sidenote changed elsewhere. Your local writing is still here.</p>
                <button type="button" onClick={() => { void keepLocal(); }}>Save mine</button>
                <button type="button" onClick={reloadStored}>Reload stored</button>
              </div>
            )}
            {saveState === 'error' && (
              <div className="sidenote-warning" role="alert">
                <p>Your writing is still here, but it could not be saved.</p>
                <button type="button" onClick={() => { void flush(); }}>Retry save</button>
              </div>
            )}
            {streamSaveErrorThreadId === activeThread.threadId && (
              <div className="sidenote-warning" role="alert">
                <p>The Stream copy is visible but not saved.</p>
                <button type="button" onClick={onRetryStreamSave}>Retry Stream save</button>
              </div>
            )}

            {pendingAI && (
              <section className="sidenote-proposal" aria-live="polite">
                <span className="sidenote-proposal-label">AI proposal</span>
                <p className="sidenote-proposal-question">{pendingAI.prompt}</p>
                {pendingAI.response ? (
                  <AIResponse
                    markdown={pendingAI.response}
                    sourceManifest={pendingAI.exchange?.sourceManifest ?? '{}'}
                    onOpenPDFDestination={onOpenPDFDestination}
                  />
                ) : !pendingAI.error ? <p className="sidenote-ai-waiting">Thinking…</p> : null}
                {pendingAI.sentContext && (
                  <SentContext facts={pendingAI.sentContext} onOpenPDFDestination={onOpenPDFDestination} />
                )}
                {pendingAI.error ? (
                  <div className="sidenote-proposal-actions" role="alert">
                    <span>{pendingAI.error}</span>
                    <button type="button" onClick={() => {
                      setPrompt(pendingAI.prompt);
                      activePromptRef.current = null;
                      setPendingAI(null);
                    }}>Edit and retry</button>
                    <button type="button" onClick={() => setPendingAI(null)}>Dismiss</button>
                  </div>
                ) : pendingAI.exchange ? (
                  <div className="sidenote-proposal-actions">
                    <button type="button" className="sidenote-keep" onClick={() => { void keepAnswer(); }}>
                      {pendingAI.localApplied ? 'Retry save' : 'Keep in Sidenote'}
                    </button>
                    <button type="button" onClick={() => { void discardAnswer(); }}>Discard</button>
                  </div>
                ) : (
                  <button type="button" onClick={cancelAI}>Stop</button>
                )}
              </section>
            )}
          </div>

          <div className="sidenote-footer">
            {placementAnchors.length === 1 && (
              <button
                type="button"
                className="sidenote-placement-link"
                onClick={() => { onLocateAnchor?.(placementAnchors[0]); }}
              >
                Added to Stream · 1
              </button>
            )}
            {placementAnchors.length > 1 && (
              <details className="sidenote-placements">
                <summary>Added to Stream · {placementAnchors.length}</summary>
                <div>
                  {placementAnchors.map((anchor, index) => (
                    <button
                      key={anchor.anchorId}
                      type="button"
                      onClick={() => { onLocateAnchor?.(anchor); }}
                    >
                      View copy {index + 1}
                    </button>
                  ))}
                </div>
              </details>
            )}
            {formats && (
              <div className="sidenote-formatbar" aria-label="Sidenote formatting">
                {([
                  ['B', formats.bold, toggleBold],
                  ['I', formats.italic, toggleItalic],
                  ['U', formats.underline, toggleUnderline],
                  ['Quote', formats.blockquote, toggleBlockquote],
                  ['List', formats.bulletList, toggleBulletList],
                ] as Array<[string, boolean, Command]>).map(([label, active, command]) => (
                  <button
                    key={String(label)}
                    type="button"
                    className={active ? 'is-active' : ''}
                    aria-pressed={Boolean(active)}
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={() => {
                      const editorAPI = editorRef.current;
                      if (editorAPI) command(editorAPI.view.state, editorAPI.view.dispatch, editorAPI.view);
                    }}
                  >{label}</button>
                ))}
                {onPromote && promotionText && (
                  <div className="sidenote-promote">
                    <button
                      type="button"
                      className="sidenote-promote-main"
                      onMouseDown={(event) => event.preventDefault()}
                      onClick={() => { void promote(primaryAnchorSpanId
                        ? { kind: 'afterAnchor', anchorSpanId: primaryAnchorSpanId }
                        : { kind: 'end' }); }}
                    >
                      {primaryStreamAnchor
                        ? `Add below “${shortQuote(primaryStreamAnchor.quote ?? '')}”`
                        : 'Add to Stream'}
                    </button>
                    <details>
                      <summary aria-label="Choose where to add">⌄</summary>
                      <div>
                        <button type="button" onClick={() => { void promote({ kind: 'cursor' }); }}>At Stream cursor</button>
                        {primaryAnchorSpanId && (
                          <button type="button" onClick={() => { void promote({
                            kind: 'replaceAnchor', anchorSpanId: primaryAnchorSpanId,
                          }); }}>Replace quoted passage</button>
                        )}
                        {streamAnchors.slice(1).map((anchor) => (
                          <button key={anchor.anchorId} type="button" onClick={() => { void promote({
                            kind: 'afterAnchor', anchorSpanId: anchor.anchorSpanId!,
                          }); }}>Below “{trimTitle(anchor.quote ?? '', 'Stream quote')}”</button>
                        ))}
                      </div>
                    </details>
                  </div>
                )}
              </div>
            )}
            <form className="sidenote-prompt" onSubmit={(event) => { event.preventDefault(); void sendPrompt(); }}>
              <textarea
                aria-label="Ask AI in this Sidenote"
                value={prompt}
                disabled={Boolean(pendingAI) || preparingAI}
                placeholder="Ask AI — sees this Sidenote’s quotes and your writing"
                onChange={(event) => setPrompt(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key !== 'Enter' || (!event.metaKey && !event.ctrlKey)) return;
                  event.preventDefault();
                  void sendPrompt();
                }}
              />
              <button type="submit" disabled={!prompt.trim() || saveState !== 'saved' || Boolean(pendingAI)}>
                {preparingAI ? 'Preparing…' : 'Ask'}
              </button>
            </form>
          </div>
        </div>
      ) : (
        <div className="sidenote-list">
          {loading && <p className="sidenote-list-state" role="status">Loading Sidenotes…</p>}
          {!loading && loadError && (
            <div className="sidenote-list-state" role="alert">
              <p>Sidenotes could not be loaded.</p>
              <button type="button" onClick={() => { void refreshList(); }}>Try again</button>
            </div>
          )}
          {!loading && !loadError && threads.length === 0 && (
            <p className="sidenote-list-state">Select a passage in the Stream or PDF, then choose “New Sidenote.”</p>
          )}
          {!loading && !loadError && threads.map((thread) => (
            <button key={thread.threadId} type="button" className="sidenote-list-item" onClick={() => { void openThread(thread.threadId); }}>
              <strong>{displayTitle(thread)}</strong>
              <span>{sourceLabels(thread).join(' · ') || 'Stream'}</span>
              <time dateTime={thread.updatedAt}>{relativeTime(thread.updatedAt)}</time>
            </button>
          ))}
        </div>
      )}

      {historyOpen && (
        <Modal
          className="sidenote-modal"
          aria-labelledby="sidenote-history-title"
          onRequestClose={() => setHistoryOpen(false)}
        >
          <h2 id="sidenote-history-title">AI history</h2>
          <div className="sidenote-history">
            {history.length === 0 && <p>No resolved AI proposals yet.</p>}
            {history.map((exchange) => (
              <article key={exchange.requestId}>
                <span>
                  {exchange.threadDisposition === 'discarded' ? 'Discarded' : 'Kept'} · {relativeTime(exchange.createdAt)}
                </span>
                <h3>{exchange.userInput}</h3>
                <AIResponse
                  markdown={exchange.responseRaw}
                  sourceManifest={exchange.sourceManifest}
                  onOpenPDFDestination={onOpenPDFDestination}
                />
                {parseThreadAISentFacts(exchange.sourceManifest) && (
                  <SentContext
                    facts={parseThreadAISentFacts(exchange.sourceManifest)!}
                    onOpenPDFDestination={onOpenPDFDestination}
                  />
                )}
              </article>
            ))}
          </div>
        </Modal>
      )}
      {deleteConfirm && (
        <Modal
          className="sidenote-modal"
          aria-labelledby="sidenote-delete-title"
          onRequestClose={() => setDeleteConfirm(false)}
        >
          <h2 id="sidenote-delete-title">Delete this Sidenote?</h2>
          <p>Its writing, quotes, and AI history will be removed. Stream text already copied from it will stay.</p>
          <div className="modal-actions">
            <button type="button" onClick={() => setDeleteConfirm(false)}>Cancel</button>
            <button type="button" className="danger" onClick={() => { void deleteActive(); }}>Delete Sidenote</button>
          </div>
        </Modal>
      )}
    </aside>
  );
});
