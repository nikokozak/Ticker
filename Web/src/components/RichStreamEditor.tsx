import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react';
import type { Slice } from 'prosemirror-model';
import { TextSelection, type Command, type Transaction } from 'prosemirror-state';
import {
  bridge,
  addStreamThreadAnchor,
  createStreamThread,
  getExchange,
  listStreamThreads,
  type DocumentAIVerb,
  type SourceTitlePayload,
  type StreamDocumentConflictPayload,
} from '../types/bridge';
import type {
  AIExchangeJSON,
  SourceReference,
  SourceScope,
  Stream,
  StreamAppendInboxJSON,
  StreamThreadAnchorJSON,
  StreamThreadJSON,
} from '../types/models';
import { ExchangeOverlay, type ExchangeManifestEntry } from './ExchangeOverlay';
import { EyeIcon, XIcon } from './icons';
import { Modal } from './Modal';
import { SourcesModal } from './SourcesModal';
import {
  ThreadDrawer,
  buildSidenoteDocumentJSON,
  type ThreadDrawerHandle,
  type SidenotePromotionRequest,
} from './ThreadDrawer';
import {
  nextSourceScope,
  parsePDFSectionActionRequest,
  type PDFSectionActionRequest,
} from './StreamEditor';
import { createRichTextEditor, type RichTextEditor } from '../richtext/editor';
import {
  aiWritingRange,
  insertImage,
  insertSidenoteWork,
  removePDFHighlightLink,
  revealPDFHighlight,
  selectedPDFHighlight,
  selectText,
  setAIWritingRange,
  streamAIMarkdown,
  sidenoteInsertionTarget,
} from '../richtext/operations';
import { DocumentSession, type SaveState } from '../richtext/session';
import {
  addProvenanceSpans,
  dissolveProvenanceSpans,
  hashProvenanceText,
  provenanceSpanAt,
  provenanceSpans,
  spanFromJSON,
  type ProvenanceSpanJSON,
} from '../richtext/provenance';
import { parseRawSpans, type PendingAppend } from '../richtext/pendingAppends';
import { useBridgeMessages } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';
import {
  buildProvenanceLine,
  parseDocumentAICitations,
  swapCitationMarkersWithMetadata,
} from '../utils/citationMarkers';
import {
  beginPDFAnchorPick,
  buildPDFQuoteSnippet,
  buildTickerPDFLinkURL,
  mapPendingPDFAnchorSelection,
  type PendingPDFAnchorSelection,
} from '../utils/pdfAnchorSelection';
import { computeSelectionMenuPlacement } from '../utils/selectionMenuPlacement';
import {
  activeFormats,
  toggleBlockquote,
  toggleBold,
  toggleBulletList,
  toggleCode,
  toggleHeading,
  toggleItalic,
  toggleOrderedList,
  toggleUnderline,
} from '../richtext/commands';
import '../richtext/editor.css';

/**
 * The editor page, on the ProseMirror editor.
 *
 * The component is deliberately thin. Everything that can be wrong in a way that
 * loses a user's writing — the codec, save/append/conflict, provenance — lives in
 * `src/richtext/` with its own tests. What is left here is wiring: the bridge on
 * one side, the chrome on the other.
 */

interface RichStreamEditorProps {
  stream: Stream;
  onBack: () => void;
  onDelete: () => void;
  onFlushAvailable?: (flush: (() => Promise<boolean>) | null) => void;
  pendingMatchText?: string | null;
  pendingSourceId?: string | null;
  onClearPendingMatch?: () => void;
  onClearPendingSource?: () => void;
}

const PDF_URL_PREFIX = 'ticker-pdf://';
const THREAD_URL_PREFIX = 'ticker-thread://';

function readBlobAsBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const data = String(reader.result).split(',')[1];
      if (data) resolve(data);
      else reject(new Error('Invalid image encoding.'));
    };
    reader.onerror = () => reject(new Error('Failed to read image data.'));
    reader.readAsDataURL(blob);
  });
}

interface ActiveDocumentAI {
  requestId: string;
  editor: RichTextEditor;
  original: Slice;
  stream: ReturnType<typeof streamAIMarkdown>;
  verb: Exclude<DocumentAIVerb, 'challenge'>;
  model?: string;
}

type PromptIntent = {
  kind: 'document';
  verb: 'ask' | 'rewrite';
} | {
  kind: 'pdfSection';
  request: PDFSectionActionRequest;
};

interface PDFPaneState {
  visible: boolean;
  streamId?: string;
  sourceName?: string;
  shortTitle?: string;
}

interface PDFThreadRequest {
  streamId: string;
  sourceId: string;
  highlightId: string;
  quote: string;
  sourceName?: string;
  shortTitle?: string;
  page: number;
  createdAt: string;
  rects: Array<{ page: number; x: number; y: number; w: number; h: number }>;
}

interface SelectionMenuState {
  visible: boolean;
  left: number;
  top: number;
  from: number;
  to: number;
}

interface SidenoteMarkerChooser {
  threadIds: string[];
  left: number;
  top: number;
}

function documentAITarget(editor: RichTextEditor): { from: number; to: number; text: string } | null {
  const { doc, selection } = editor.view.state;
  const from = selection.empty ? selection.$head.start() : selection.from;
  const to = selection.empty ? selection.$head.end() : selection.to;
  const text = doc.textBetween(from, to, '\n', '').trim();
  return text ? { from, to, text } : null;
}

function defaultThreadTitle(text: string): string {
  const oneLine = text.trim().replace(/\s+/g, ' ');
  return oneLine.length <= 64 ? oneLine : `${oneLine.slice(0, 61)}…`;
}

function sidenoteSourceLabel(thread: StreamThreadJSON): string {
  const labels = (thread.anchors ?? []).flatMap((anchor) => {
    if (anchor.kind === 'placement') return [];
    if (anchor.kind === 'stream_quote') return ['Stream'];
    return [anchor.sourceShortTitle || anchor.sourceName || 'PDF'];
  });
  return [...new Set(labels)].join(' · ') || 'Stream';
}

function restoreDocumentAI(editor: RichTextEditor, active: ActiveDocumentAI): void {
  const { view } = editor;
  const written = active.stream.done();
  const range = aiWritingRange(view.state) ?? written;
  const tr = view.state.tr.replaceRange(range.from, range.to, active.original);
  setAIWritingRange(tr, null).setMeta('addToHistory', false);
  view.dispatch(tr);
}

/** The store's rows, in the shape the session proves things about. */
const decodePendingAppends = (rows: Stream['pendingAppends']): PendingAppend[] => (rows ?? []).map((append) => ({
  revision: append.revision,
  separator: append.separator,
  fragment: append.fragment,
  rawSpans: parseRawSpans(append.rawSpansJSON),
}));

const SAVE_LABEL: Record<SaveState, string> = {
  saved: 'Saved',
  saving: 'Saving…',
  error: 'Save failed',
};

export function RichStreamEditor({
  stream,
  onBack,
  onDelete,
  onFlushAvailable,
  pendingMatchText,
  pendingSourceId,
  onClearPendingMatch,
  onClearPendingSource,
}: RichStreamEditorProps) {
  const host = useRef<HTMLDivElement>(null);
  const editorRef = useRef<RichTextEditor | null>(null);
  const sessionRef = useRef<DocumentSession | null>(null);
  const editorMountGeneration = useRef(0);
  const aiRequestRef = useRef<ActiveDocumentAI | null>(null);
  const aiInFlightRef = useRef(false);
  const pendingPDFAnchorSelectionRef = useRef<PendingPDFAnchorSelection | null>(null);
  const pendingThreadAnchorSelectionRef = useRef<PendingPDFAnchorSelection | null>(null);
  const threadCreateInFlightRef = useRef(false);
  const titleInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const streamOverflowMenuRef = useRef<HTMLDetailsElement>(null);
  const selectionActionMenuRef = useRef<HTMLDivElement>(null);
  const threadDrawerRef = useRef<ThreadDrawerHandle>(null);
  const threadButtonRef = useRef<HTMLButtonElement>(null);
  const markerChooserRef = useRef<HTMLDivElement>(null);
  const pendingSidenotePlacementRef = useRef<{
    threadId: string;
    anchorId: string;
    anchorSpanId: string;
  } | null>(null);
  // ponytail: one stream-wide PDF AI lock; track host operation ids if concurrent
  // PDF jobs ever become a supported workflow.
  const pdfAIInFlightRef = useRef(false);
  const threadAIInFlightRef = useRef(false);
  const consumedPendingSourceRef = useRef<string | null>(null);

  const [editor, setEditor] = useState<RichTextEditor | null>(null);
  const [saveState, setSaveState] = useState<SaveState>('saved');
  const [aiRunning, setAIRunning] = useState(false);
  const [threadAIRunning, setThreadAIRunning] = useState(false);
  const [aiDetail, setAIDetail] = useState<string | null>(null);
  const [sourceIndexNotice, setSourceIndexNotice] = useState<string | null>(null);
  const [promptIntent, setPromptIntent] = useState<PromptIntent | null>(null);
  const [promptValue, setPromptValue] = useState('');
  const [leaving, setLeaving] = useState(false);
  const deleting = useRef(false);
  const [xray, setXray] = useState(false);
  const [exchangeOverlay, setExchangeOverlay] = useState<AIExchangeJSON | null>(null);
  const [title, setTitle] = useState(stream.title);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showSourcesModal, setShowSourcesModal] = useState(false);
  const [showThreads, setShowThreads] = useState(false);
  const [activeSidenote, setActiveSidenote] = useState<StreamThreadJSON | null>(null);
  const [sidenotes, setSidenotes] = useState<StreamThreadJSON[]>([]);
  const sidenotesRef = useRef<StreamThreadJSON[]>([]);
  const [markerChooser, setMarkerChooser] = useState<SidenoteMarkerChooser | null>(null);
  const [threadInsertionSaveFailed, setThreadInsertionSaveFailed] = useState<string | null>(null);
  const [threadCreating, setThreadCreating] = useState(false);
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);
  const [sourceScope, setSourceScope] = useState<SourceScope>(stream.sourceScope ?? 'auto');
  const [pdfPaneState, setPDFPaneState] = useState<PDFPaneState>({ visible: false });
  const [selectionMenuPanel, setSelectionMenuPanel] = useState<'ai' | 'more' | null>(null);
  const [selectionMenu, setSelectionMenu] = useState<SelectionMenuState>({
    visible: false,
    left: 0,
    top: 0,
    from: 0,
    to: 0,
  });
  const [, redraw] = useState(0);
  const addToast = useToastStore((state) => state.addToast);
  const { sources, setSources } = useBridgeMessages({
    streamId: stream.id,
    initialSources: stream.sources,
    editorAPI: editor ? {
      insertImage: (src) => {
        insertImage(editor.view, { src, alt: 'image' });
        editor.view.focus();
      },
    } : null,
  });

  const rememberSidenotes = useCallback((next: StreamThreadJSON[] | undefined) => {
    const valid = Array.isArray(next) ? next : [];
    sidenotesRef.current = valid;
    setSidenotes(valid);
  }, []);

  const rememberSidenote = useCallback((thread: StreamThreadJSON) => {
    rememberSidenotes([
      thread,
      ...sidenotesRef.current.filter((candidate) => candidate.threadId !== thread.threadId),
    ]);
  }, [rememberSidenotes]);

  const rememberSidenoteAnchor = useCallback((threadId: string, anchor: StreamThreadAnchorJSON) => {
    const thread = sidenotesRef.current.find((candidate) => candidate.threadId === threadId);
    if (!thread) return;
    rememberSidenote({
      ...thread,
      anchors: [
        ...(thread.anchors ?? []).filter((candidate) => candidate.anchorId !== anchor.anchorId),
        anchor,
      ],
    });
  }, [rememberSidenote]);

  useEffect(() => {
    let live = true;
    void listStreamThreads(stream.id)
      .then((result) => { if (live) rememberSidenotes(result.threads); })
      .catch(() => undefined);
    return () => { live = false; };
  }, [rememberSidenotes, stream.id]);

  const cancelDocumentAI = useCallback((notifyHost = true) => {
    const active = aiRequestRef.current;
    if (!active) {
      // A save may still be draining before the request is sent. Clearing this
      // token makes that continuation stop instead of starting AI while leaving.
      aiInFlightRef.current = false;
      return;
    }
    if (notifyHost) {
      bridge.send({ type: 'cancelDocumentAI', payload: { requestId: active.requestId } });
    }
    const currentEditor = editorRef.current;
    if (currentEditor) restoreDocumentAI(currentEditor, active);
    aiRequestRef.current = null;
    aiInFlightRef.current = false;
    setAIRunning(false);
    setAIDetail(null);
    setSourceIndexNotice(null);
  }, []);

  const flushAll = useCallback(async () => {
    cancelDocumentAI();
    threadDrawerRef.current?.cancelAI();
    if (!await (threadDrawerRef.current?.leave() ?? Promise.resolve(true))) return false;
    return sessionRef.current?.saveNow() ?? Promise.resolve(true);
  }, [cancelDocumentAI]);

  useEffect(() => {
    onFlushAvailable?.(flushAll);
    return () => onFlushAvailable?.(null);
  }, [flushAll, onFlushAvailable]);

  const canStartAI = useCallback(() => {
    if (!aiInFlightRef.current && !pdfAIInFlightRef.current && !threadAIInFlightRef.current) return true;
    addToast('Wait for the current AI operation to finish, or stop it first.', 'info');
    return false;
  }, [addToast]);

  const beginThreadAI = useCallback(() => {
    if (!canStartAI()) return false;
    threadAIInFlightRef.current = true;
    setThreadAIRunning(true);
    return true;
  }, [canStartAI]);

  const endThreadAI = useCallback(() => {
    threadAIInFlightRef.current = false;
    setThreadAIRunning(false);
  }, []);

  const startPDFSectionAI = useCallback((
    request: PDFSectionActionRequest,
    prompt?: string,
  ) => {
    if (!canStartAI()) return false;
    pdfAIInFlightRef.current = true;
    if (prompt) {
      bridge.send({
        type: 'runPdfSectionAI',
        payload: {
          action: request.action,
          streamId: request.streamId,
          sourceId: request.sourceId,
          page: request.page,
          prompt,
        },
      });
    } else {
      bridge.send({
        type: 'runPdfSectionAI',
        payload: {
          action: request.action,
          streamId: request.streamId,
          sourceId: request.sourceId,
          page: request.page,
        },
      });
    }
    return true;
  }, [canStartAI]);

  const cycleSourceScope = useCallback(() => {
    setSourceScope((previous) => {
      const scope = nextSourceScope(previous);
      bridge.send({
        type: 'setSourceScope',
        payload: { streamId: stream.id, scope },
      });
      return scope;
    });
  }, [stream.id]);

  const openSource = useCallback((source: SourceReference) => {
    bridge.send({ type: 'openSource', payload: { sourceId: source.id } });
  }, []);

  const openExchangeManifestEntry = useCallback((entry: ExchangeManifestEntry) => {
    bridge.send({
      type: 'openPdfDestination',
      payload: {
        streamId: stream.id,
        sourceId: entry.sourceId,
        page: entry.page,
        chunkId: entry.chunkId,
      },
    });
  }, [stream.id]);

  const removeSource = useCallback((sourceId: string) => {
    setSources((previous) => previous.filter((source) => source.id !== sourceId));
  }, [setSources]);

  const setSourceAIExclusion = useCallback((sourceId: string, aiExcluded: boolean) => {
    setSources((previous) => previous.map((source) => (
      source.id === sourceId ? { ...source, aiExcluded } : source
    )));
  }, [setSources]);

  const hideSelectionMenu = useCallback(() => {
    setSelectionMenuPanel(null);
    setSelectionMenu((previous) => (
      previous.visible ? { ...previous, visible: false } : previous
    ));
  }, []);

  const getSelectionMenuPlacement = useCallback((
    measuredMenuSize?: { width: number; height: number },
  ) => {
    const view = editorRef.current?.view;
    const shell = editorShellRef.current;
    if (!view || !shell || view.state.selection.empty) return null;

    const { from, to } = view.state.selection;
    const fromCoords = view.coordsAtPos(from);
    const toCoords = view.coordsAtPos(to);
    return computeSelectionMenuPlacement({
      coords: {
        left: Math.min(fromCoords.left, toCoords.left),
        right: Math.max(fromCoords.right, toCoords.right),
        top: Math.min(fromCoords.top, toCoords.top),
        bottom: Math.max(fromCoords.bottom, toCoords.bottom),
      },
      shellRect: shell.getBoundingClientRect(),
      menuSize: measuredMenuSize,
      viewportHeight: window.innerHeight,
    });
  }, []);

  const updateSelectionMenu = useCallback(() => {
    const view = editorRef.current?.view;
    if (!view || view.state.selection.empty) {
      hideSelectionMenu();
      return;
    }
    const { from, to } = view.state.selection;
    if (!view.state.doc.textBetween(from, to, '\n', '').trim()) {
      hideSelectionMenu();
      return;
    }
    const placement = getSelectionMenuPlacement();
    if (!placement) {
      hideSelectionMenu();
      return;
    }
    setSelectionMenuPanel(null);
    setSelectionMenu({ visible: true, ...placement, from, to });
  }, [getSelectionMenuPlacement, hideSelectionMenu]);

  // Which formatting buttons are lit depends on the SELECTION, so the menu has to
  // redraw on every transaction and not only on edits.
  const onUpdate = useCallback(() => {
    redraw((n) => n + 1);
    updateSelectionMenu();
  }, [updateSelectionMenu]);

  useLayoutEffect(() => {
    if (!selectionMenu.visible) return;
    const menu = selectionActionMenuRef.current;
    if (!menu || menu.offsetWidth <= 0 || menu.offsetHeight <= 0) return;
    const placement = getSelectionMenuPlacement({
      width: menu.offsetWidth,
      height: menu.offsetHeight,
    });
    if (!placement) return;
    setSelectionMenu((previous) => (
      previous.visible
      && Math.abs(previous.left - placement.left) < 0.5
      && Math.abs(previous.top - placement.top) < 0.5
        ? previous
        : { ...previous, ...placement }
    ));
  }, [
    getSelectionMenuPlacement,
    pdfPaneState.streamId,
    pdfPaneState.visible,
    selectionMenu.from,
    selectionMenu.to,
    selectionMenu.visible,
    selectionMenuPanel,
  ]);
  const onTransaction = useCallback((transaction: Transaction) => {
    const mapper = {
      mapPos: (pos: number, assoc?: number) => transaction.mapping.map(pos, assoc),
    };
    const pendingPDF = pendingPDFAnchorSelectionRef.current;
    if (pendingPDF) {
      pendingPDFAnchorSelectionRef.current = mapPendingPDFAnchorSelection(pendingPDF, mapper);
    }
    const pendingThread = pendingThreadAnchorSelectionRef.current;
    if (pendingThread) {
      pendingThreadAnchorSelectionRef.current = mapPendingPDFAnchorSelection(pendingThread, mapper);
    }
  }, []);

  const locateThreadAnchor = useCallback((anchor: StreamThreadAnchorJSON) => {
    if (!anchor.anchorSpanId) return true;
    const view = editorRef.current?.view;
    if (!view) return false;
    const span = provenanceSpans(view.state)
      .find((candidate) => candidate.spanId === anchor.anchorSpanId);
    if (!span) return false;

    const $from = view.state.doc.resolve(span.from);
    let depth = $from.depth;
    while (depth > 0 && !$from.node(depth).isBlock) depth -= 1;
    const blockDOM = view.nodeDOM(depth > 0 ? $from.before(depth) : span.from);
    const direct = (blockDOM instanceof Element ? blockDOM : blockDOM?.parentElement)
      ?.closest('p, h1, h2, h3, li, blockquote');
    const element = direct ?? [...view.dom.querySelectorAll('p, h1, h2, h3, li, blockquote')]
      .find((candidate) => {
        const from = view.posAtDOM(candidate, 0);
        const to = view.posAtDOM(candidate, candidate.childNodes.length);
        return span.from <= to && span.to >= from;
      });
    element?.scrollIntoView({ block: 'center' });
    element?.classList.add('sidenote-anchor-reveal');
    window.setTimeout(() => element?.classList.remove('sidenote-anchor-reveal'), 1_600);
    return hashProvenanceText(view.state.doc, span) === span.textHash;
  }, []);

  const removeSidenoteMarkers = useCallback(async (threadId: string) => {
    const currentEditor = editorRef.current;
    const session = sessionRef.current;
    if (currentEditor && session) {
      const spanIds = provenanceSpans(currentEditor.view.state)
        .filter((span) => span.origin === 'thread' && span.meta.threadId === threadId)
        .map((span) => span.spanId);
      if (spanIds.length) {
        currentEditor.view.dispatch(
          dissolveProvenanceSpans(currentEditor.view.state.tr, spanIds)
            .setMeta('addToHistory', false),
        );
        session.documentChanged();
        if (!await session.saveNow()) {
          addToast('The Sidenote was deleted, but its Stream markers still need to save.', 'warning');
        }
      }
    }
    rememberSidenotes(sidenotesRef.current.filter((thread) => thread.threadId !== threadId));
  }, [addToast, rememberSidenotes]);

  /**
   * A citation is not an external URL. Swift rejects any non-HTTP scheme from
   * openExternalURL, so routing `ticker-pdf://` there did nothing at all — the
   * click was simply swallowed. Citations go to the PDF pane instead.
   */
  const openLink = useCallback((href: string) => {
    if (href.startsWith(THREAD_URL_PREFIX)) {
      const threadId = href.slice(THREAD_URL_PREFIX.length).split(/[?#]/, 1)[0];
      if (!threadId) {
        addToast('This Sidenote link is damaged.', 'error');
        return;
      }
      setShowThreads(true);
      void threadDrawerRef.current?.openThread(threadId);
      return;
    }
    if (href.startsWith(PDF_URL_PREFIX)) {
      bridge.send({ type: 'openPdfDestination', payload: { streamId: stream.id, url: href } });
      return;
    }
    bridge.send({ type: 'openExternalURL', payload: { url: href } });
  }, [addToast, stream.id]);

  const openPDFHighlightThread = useCallback(async (sourceId: string, highlightId: string) => {
    try {
      const result = await listStreamThreads(stream.id);
      const thread = result.threads.find((candidate) => (
        (candidate.sourceId === sourceId && candidate.highlightId === highlightId)
        || candidate.anchors?.some((anchor) => (
          anchor.sourceId === sourceId && anchor.highlightId === highlightId
        ))
      ));
      if (!thread) {
        addToast('This highlight is no longer linked to a Sidenote.', 'warning');
        return;
      }
      setShowThreads(true);
      hideSelectionMenu();
      if (!await threadDrawerRef.current?.openThread(thread.threadId)) {
        addToast('Save the open Sidenote before switching.', 'error');
      }
    } catch {
      addToast('This highlight could not be opened.', 'error');
    }
  }, [addToast, stream.id]);

  const retryThreadInsertionSave = useCallback(async () => {
    if (!await sessionRef.current?.saveNow()) return;
    const pending = pendingSidenotePlacementRef.current;
    if (pending) {
      try {
        const result = await addStreamThreadAnchor({
          streamId: stream.id,
          threadId: pending.threadId,
          anchor: {
            anchorId: pending.anchorId,
            kind: 'placement',
            anchorSpanId: pending.anchorSpanId,
          },
        });
        rememberSidenoteAnchor(pending.threadId, result.anchor);
        await threadDrawerRef.current?.addAnchor(result.anchor);
        pendingSidenotePlacementRef.current = null;
      } catch {
        addToast('The Stream is saved, but the Sidenote marker could not be recorded.', 'warning');
      }
    }
    setThreadInsertionSaveFailed(null);
  }, [addToast, rememberSidenoteAnchor, stream.id]);

  const startPDFSelectionThread = useCallback(async (request: PDFThreadRequest) => {
    const discardHighlight = () => bridge.send({
      type: 'deletePdfHighlight',
      payload: { streamId: request.streamId, highlightId: request.highlightId },
    });
    if (threadCreateInFlightRef.current
        || aiInFlightRef.current
        || pdfAIInFlightRef.current
        || threadAIInFlightRef.current) {
      discardHighlight();
      addToast('Finish the current operation before adding a PDF quote.', 'info');
      return;
    }

    threadCreateInFlightRef.current = true;
    setThreadCreating(true);
    let created = false;
    try {
      if (!await (threadDrawerRef.current?.flush() ?? Promise.resolve(true))) {
        throw new Error('The open Sidenote is not saved.');
      }
      const threadId = activeSidenote?.threadId ?? crypto.randomUUID();
      const anchorId = crypto.randomUUID();
      const displayAnchor: StreamThreadAnchorJSON = {
        anchorId,
        threadId,
        kind: 'pdf_quote',
        quote: request.quote,
        sourceId: request.sourceId,
        sourceName: request.sourceName,
        sourceShortTitle: request.shortTitle,
        highlightId: request.highlightId,
        sourcePage: request.page,
        createdAt: request.createdAt,
      };
      const wireAnchor = {
        anchorId,
        kind: 'pdf_quote' as const,
        quote: request.quote,
        sourceId: request.sourceId,
        highlightId: request.highlightId,
        createdAt: request.createdAt,
        page: request.page,
        rects: request.rects,
      };
      if (activeSidenote) {
        const result = await addStreamThreadAnchor({
          streamId: request.streamId,
          threadId,
          anchor: wireAnchor,
        });
        created = true;
        setShowThreads(true);
        if (!await threadDrawerRef.current?.addAnchor(result.anchor)) {
          addToast('The quote is attached, but the open Sidenote still needs to save.', 'warning');
        } else {
          addToast('Added the PDF quote to this Sidenote.', 'success');
        }
        return;
      }
      const result = await createStreamThread({
        streamId: request.streamId,
        threadId,
        title: defaultThreadTitle(request.quote),
        workingText: '',
        docJSON: buildSidenoteDocumentJSON([displayAnchor]),
        docFormatVersion: 1,
        anchorText: request.quote,
        sourceId: request.sourceId,
        highlightId: request.highlightId,
        anchors: [wireAnchor],
      });
      created = true;
      rememberSidenote(result.thread);
      setShowThreads(true);
      if (!await threadDrawerRef.current?.showThread(result.thread)) {
        addToast('The Sidenote was created. Open it from Sidenotes.', 'info');
        return;
      }
      addToast('Created a Sidenote from the PDF quote.', 'success');
    } catch {
      if (!created) discardHighlight();
      addToast('The PDF quote could not be added to a Sidenote.', 'error');
    } finally {
      threadCreateInFlightRef.current = false;
      setThreadCreating(false);
    }
  }, [activeSidenote, addToast, rememberSidenote]);

  const saveImageToAssets = useCallback(async (blob: Blob): Promise<string> => {
    const requestId = crypto.randomUUID();
    const data = await readBlobAsBase64(blob);

    return new Promise((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        unsubscribe();
        reject(new Error('Timed out while saving image.'));
      }, 15_000);
      const unsubscribe = bridge.onMessage((message) => {
        if (message.payload?.requestId !== requestId) return;
        if (message.type === 'imageSaved' && typeof message.payload.assetUrl === 'string') {
          window.clearTimeout(timeout);
          unsubscribe();
          resolve(message.payload.assetUrl);
        } else if (message.type === 'imageSaveError') {
          window.clearTimeout(timeout);
          unsubscribe();
          reject(new Error(
            typeof message.payload.error === 'string' ? message.payload.error : 'Failed to save image.',
          ));
        }
      });

      bridge.send({
        type: 'saveImage',
        payload: { streamId: stream.id, data, requestId },
      });
    });
  }, [stream.id]);

  useEffect(() => {
    if (!host.current) return undefined;
    const { docJSON, docFormatVersion } = stream.document;
    if (docFormatVersion !== 1 || typeof docJSON !== 'string') {
      // ponytail: converted rows are the launch gate; add mixed-version recovery
      // UI only if a partially converted database ever becomes a supported state.
      addToast('This stream has not been converted to the rich-text document format.', 'error');
      return undefined;
    }

    let created: RichTextEditor;
    try {
      created = createRichTextEditor({
        parent: host.current,
        docJSON,
        // Every streamed frame is temporary until completion. Letting any one of
        // them arm autosave stores a reply the user never actually received.
        onChange: () => {
          if (!aiInFlightRef.current) sessionRef.current?.documentChanged();
        },
        onTransaction,
        onUpdate,
        onOpenLink: openLink,
      });
    } catch {
      addToast('This stream’s rich-text document could not be read.', 'error');
      return undefined;
    }
    const mountGeneration = ++editorMountGeneration.current;

    const session = new DocumentSession({
      streamId: stream.id,
      editor: created,
      revision: stream.document?.revision ?? 0,
      spans: (stream.spans ?? []).map(spanFromJSON),
      pendingAppends: decodePendingAppends(stream.pendingAppends),
      inboxAppends: stream.appendInbox ?? [],
      transport: {
        // Spelled out rather than spread: the contract checker verifies this
        // payload statically against bridge.v2.json, and can only do that for a
        // literal.
        save: ({
          streamId,
          docJSON: savedDocJSON,
          docFormatVersion: savedDocFormatVersion,
          markdown,
          baseRevision,
          spans,
          resolvedPendingThrough,
          consumedInboxThrough,
        }) => bridge.sendAsync<{ revision: number }>(
          'saveRichStreamDocument',
          {
            streamId,
            docJSON: savedDocJSON,
            docFormatVersion: savedDocFormatVersion,
            markdown,
            baseRevision,
            spans,
            resolvedPendingThrough,
            consumedInboxThrough,
          },
        ),
        reload: (streamId) => bridge.send({ type: 'loadStream', payload: { id: streamId } }),
        onSaveStateChange: setSaveState,
        onError: (message) => addToast(message, 'error'),
      },
    });

    editorRef.current = created;
    sessionRef.current = session;
    setEditor(created);

    const scroller = host.current.closest('.stream-content') as HTMLElement;
    let scrollSaveTimer: number | undefined;
    const sendScrollPosition = () => bridge.send({
      type: 'saveScrollPosition',
      payload: { streamId: stream.id, offset: Math.max(0, scroller.scrollTop) },
    });
    const saveScrollPosition = () => {
      updateSelectionMenu();
      window.clearTimeout(scrollSaveTimer);
      scrollSaveTimer = window.setTimeout(() => {
        scrollSaveTimer = undefined;
        sendScrollPosition();
      }, 1_000);
    };
    scroller.scrollTop = Math.max(0, stream.document?.scrollOffset ?? 0);
    scroller.addEventListener('scroll', saveScrollPosition, { passive: true });

    return () => {
      scroller.removeEventListener('scroll', saveScrollPosition);
      if (scrollSaveTimer !== undefined) {
        window.clearTimeout(scrollSaveTimer);
        sendScrollPosition();
      }
      const active = aiRequestRef.current;
      if (active) {
        bridge.send({ type: 'cancelDocumentAI', payload: { requestId: active.requestId } });
        restoreDocumentAI(created, active);
        aiRequestRef.current = null;
      }
      aiInFlightRef.current = false;
      editorRef.current = null;
      sessionRef.current = null;
      setEditor(null);

      // Strict Mode mounts the replacement before this save can answer. Leaving
      // both EditorViews in one host wedges WebKit's selection/event machinery.
      // ponytail: keep the detached view alive for its state; snapshot the save
      // before teardown if a host reply can remain pending long enough to matter.
      created.view.dom.remove();

      // Saving a document the user just deleted writes a row for a stream that is
      // gone, and reports the failure as if their writing were at risk.
      if (deleting.current) {
        session.discard();
        created.destroy();
        return;
      }

      queueMicrotask(() => {
        if (editorMountGeneration.current !== mountGeneration) {
          // React replays effects before paint in development. Saving that
          // throwaway inbox reduction races the real view for the same watermark.
          // ponytail: identify the replay by its immediate replacement; own the
          // session above the effect if React ever replays after user input.
          session.discard();
          created.destroy();
          return;
        }

        // The backstop, for unmounts that did not come through `leave` below —
        // nothing may tear the editor down before what is pending has been written,
        // because the write reads the document.
        void session.destroy().then((saved) => {
          if (!saved) addToast('Some changes could not be saved before leaving the stream.', 'error');
          created.destroy();
        });
      });
    };
  }, [addToast, onTransaction, onUpdate, openLink, stream.id, updateSelectionMenu]);

  useEffect(() => {
    if (!editor) return undefined;
    let live = true;

    // ponytail: uploads land at the live cursor; keep a mapped bookmark if upload
    // latency makes cursor drift observable.
    const insertFile = async (file: File) => {
      try {
        const src = await saveImageToAssets(file);
        if (!live) {
          // ponytail: this leaves the saved asset orphaned; add a host append
          // command when uploads must finish after navigation.
          addToast('Image was saved but not added because the stream closed. Paste it again.', 'error');
          return;
        }
        insertImage(editor.view, {
          src,
          alt: file.name.replace(/\.[^.]+$/, '') || 'image',
        });
        editor.view.focus();
      } catch (error) {
        if (!live) return;
        addToast(error instanceof Error ? error.message : 'Failed to insert image.', 'error');
      }
    };
    const paste = (event: ClipboardEvent) => {
      const file = Array.from(event.clipboardData?.items ?? [])
        .find((item) => item.type.startsWith('image/'))?.getAsFile();
      if (!file) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const text = event.clipboardData?.getData('text/plain') ?? '';
      if (text.trim()) {
        editor.view.pasteText(text, event);
        return;
      }
      void insertFile(file);
    };
    const drop = (event: DragEvent) => {
      const file = Array.from(event.dataTransfer?.files ?? [])
        .find((candidate) => candidate.type.startsWith('image/'));
      if (!file) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      void insertFile(file);
    };
    const dragover = (event: DragEvent) => {
      if (Array.from(event.dataTransfer?.items ?? []).some((item) => item.type.startsWith('image/'))) {
        event.preventDefault();
      }
    };

    editor.view.dom.addEventListener('paste', paste, true);
    editor.view.dom.addEventListener('drop', drop, true);
    editor.view.dom.addEventListener('dragover', dragover, true);
    return () => {
      live = false;
      editor.view.dom.removeEventListener('paste', paste, true);
      editor.view.dom.removeEventListener('drop', drop, true);
      editor.view.dom.removeEventListener('dragover', dragover, true);
    };
  }, [addToast, editor, saveImageToAssets]);

  useEffect(() => {
    editor?.view.dom.parentElement?.classList.toggle('richtext-xray', xray);
  }, [editor, xray]);

  useEffect(() => {
    if (!editor) return undefined;
    const labelMarkers = () => {
      const directory = new Map(sidenotesRef.current.map((thread) => [thread.threadId, thread]));
      editor.view.dom.querySelectorAll<HTMLButtonElement>('.sidenote-marker').forEach((marker) => {
        const threadIds = marker.dataset.threadIds?.split(',').filter(Boolean) ?? [];
        const titles = threadIds.map((id) => directory.get(id)?.title).filter(Boolean) as string[];
        const label = threadIds.length > 1
          ? `Open ${threadIds.length} Sidenotes${titles.length ? `: ${titles.join(', ')}` : ''}`
          : `Open Sidenote${titles[0] ? `: ${titles[0]}` : ''}`;
        marker.setAttribute('aria-label', label);
        marker.dataset.peek = threadIds.length > 1 ? `${threadIds.length} Sidenotes` : titles[0] ?? 'Open Sidenote';
      });
    };
    const openMarker = (event: MouseEvent) => {
      const marker = event.target instanceof Element
        ? event.target.closest<HTMLButtonElement>('.sidenote-marker')
        : null;
      const threadIds = marker?.dataset.threadIds?.split(',').filter(Boolean) ?? [];
      if (!marker || !threadIds.length) return;
      event.preventDefault();
      event.stopPropagation();
      if (threadIds.length > 1) {
        const rect = marker.getBoundingClientRect();
        setMarkerChooser({
          threadIds,
          left: Math.min(rect.right + 8, window.innerWidth - 280),
          top: Math.min(rect.top, window.innerHeight - 240),
        });
        return;
      }
      setShowThreads(true);
      void threadDrawerRef.current?.openThread(threadIds[0]);
    };
    labelMarkers();
    const observer = new MutationObserver(labelMarkers);
    observer.observe(editor.view.dom, { childList: true, subtree: true });
    editor.view.dom.addEventListener('click', openMarker);
    return () => {
      observer.disconnect();
      editor.view.dom.removeEventListener('click', openMarker);
    };
  }, [editor, sidenotes]);

  useEffect(() => {
    if (!markerChooser) return;
    window.requestAnimationFrame(() => markerChooserRef.current?.querySelector<HTMLButtonElement>('button')?.focus());
  }, [markerChooser]);

  useEffect(() => {
    if (!editor || !xray) return undefined;
    let live = true;
    const inspect = (event: MouseEvent) => {
      const target = event.target instanceof Element
        ? event.target.closest<HTMLElement>('.richtext-provenance')
        : null;
      if (!target) return;
      const span = provenanceSpanAt(
        editor.view.state,
        editor.view.posAtDOM(target, 0),
      );
      if (!span?.requestId) return;

      // ProseMirror moves the selection on mousedown. Opening provenance is not an
      // edit, so it must not retarget the cursor before the exchange arrives.
      event.preventDefault();
      event.stopImmediatePropagation();
      void getExchange(span.requestId)
        .then(({ exchange }) => {
          if (live && exchange?.streamId === stream.id) setExchangeOverlay(exchange);
        })
        .catch(() => undefined);
    };

    editor.view.dom.addEventListener('mousedown', inspect, true);
    return () => {
      live = false;
      editor.view.dom.removeEventListener('mousedown', inspect, true);
    };
  }, [editor, stream.id, xray]);

  useEffect(() => {
    if (!editor || !pendingMatchText) return;
    selectText(editor.view, pendingMatchText);
    onClearPendingMatch?.();
  }, [editor, onClearPendingMatch, pendingMatchText]);

  useEffect(() => {
    setSourceScope(stream.sourceScope ?? 'auto');
  }, [stream.sourceScope]);

  useEffect(() => {
    if (!pendingSourceId) {
      consumedPendingSourceRef.current = null;
      return;
    }
    if (consumedPendingSourceRef.current === pendingSourceId) return;
    consumedPendingSourceRef.current = pendingSourceId;

    if (sources.some((source) => source.id === pendingSourceId)) {
      setHighlightedSourceId(pendingSourceId);
      setShowSourcesModal(true);
    }
    onClearPendingSource?.();
  }, [onClearPendingSource, pendingSourceId, sources]);

  const startDocumentAI = useCallback(async (
    verb: Exclude<DocumentAIVerb, 'challenge'> = 'develop',
    instruction?: string,
  ) => {
    const currentEditor = editorRef.current;
    const session = sessionRef.current;
    if (!currentEditor || !session || !canStartAI()) return;

    // Clear any already-armed save before streaming begins. Merely suppressing the
    // chunks is insufficient: a timer from the edit that started the request can
    // otherwise fire over the first half of the reply.
    aiInFlightRef.current = true;
    const saved = await session.saveNow();
    if (!aiInFlightRef.current || editorRef.current !== currentEditor || sessionRef.current !== session) {
      aiInFlightRef.current = false;
      return;
    }
    if (!saved) {
      aiInFlightRef.current = false;
      addToast('Save your changes before asking AI to rewrite them.', 'error');
      return;
    }

    const target = documentAITarget(currentEditor);
    if (!target) {
      aiInFlightRef.current = false;
      addToast('Select text or place the cursor in a paragraph to send.', 'info');
      return;
    }

    let range = { from: target.from, to: target.to };
    if (verb === 'ask' || verb === 'define') {
      const $to = currentEditor.view.state.doc.resolve(target.to);
      const at = $to.depth ? $to.after() : target.to;
      range = { from: at, to: at };
    }

    const requestId = crypto.randomUUID();
    aiRequestRef.current = {
      requestId,
      editor: currentEditor,
      original: currentEditor.view.state.doc.slice(range.from, range.to),
      stream: streamAIMarkdown(currentEditor.view, range),
      verb,
    };
    setAIRunning(true);
    setAIDetail('AI is writing');
    const indexingSource = sources.find((source) => (
      source.indexStatus === 'indexing' || source.indexStatus === 'pending'
    ));
    setSourceIndexNotice(indexingSource
      ? `Still indexing ${indexingSource.shortTitle || indexingSource.displayName} — answers may not cover it yet.`
      : null);
    // ponytail: text-only first slice; collect selected image nodes when this
    // page exposes multimodal document-AI actions.
    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: instruction ?? target.text,
        context: instruction ? target.text : undefined,
        sourceScope,
        verb,
        imageURLs: [],
      },
    });
  }, [addToast, canStartAI, sourceScope, sources, stream.id]);

  const openDocumentAIPrompt = useCallback((verb: 'ask' | 'rewrite') => {
    const currentEditor = editorRef.current;
    if (!currentEditor || !documentAITarget(currentEditor)) {
      addToast('Select text or place the cursor in a paragraph to use as context.', 'info');
      return;
    }
    setPromptValue('');
    setPromptIntent({ kind: 'document', verb });
  }, [addToast]);

  const closeDocumentAIPrompt = useCallback(() => {
    setPromptIntent(null);
    setPromptValue('');
  }, []);

  const sendDocumentAIPrompt = useCallback(() => {
    const instruction = promptValue.trim();
    if (!promptIntent || !instruction) return;
    if (promptIntent.kind === 'pdfSection') {
      if (startPDFSectionAI(promptIntent.request, instruction)) closeDocumentAIPrompt();
      return;
    }
    const { verb } = promptIntent;
    closeDocumentAIPrompt();
    void startDocumentAI(verb, instruction);
  }, [
    closeDocumentAIPrompt,
    promptIntent,
    promptValue,
    startDocumentAI,
    startPDFSectionAI,
  ]);

  /**
   * Leaving is not a render, it is a write that can fail.
   *
   * Cleanup cannot gate it: by the time an effect's teardown runs, the navigation
   * has already happened, so a failed save could only be reported after the editor
   * — the one place the text still existed — was gone. So the save happens first
   * and the page is left only if it actually landed.
   */
  const leave = useCallback(async () => {
    cancelDocumentAI();
    threadDrawerRef.current?.cancelAI();
    setLeaving(true);
    const threadSaved = await (threadDrawerRef.current?.leave() ?? Promise.resolve(true));
    const documentSaved = threadSaved
      ? await (sessionRef.current?.destroy() ?? Promise.resolve(true))
      : false;
    if (documentSaved) return onBack();
    setLeaving(false);
    addToast('Your changes could not be saved, so this stream stayed open.', 'error');
  }, [addToast, cancelDocumentAI, onBack]);

  const remove = useCallback(() => {
    deleting.current = true;
    onDelete();
  }, [onDelete]);

  useEffect(() => bridge.onMessage((message) => {
    const session = sessionRef.current;
    if (!session) return;
    const payload = message.payload as Record<string, unknown> | undefined;

    if (message.type === 'getEditorSelection') {
      const requestId = payload?.requestId;
      if (typeof requestId !== 'string') return;
      const view = editorRef.current?.view;
      const selection = view?.state.selection;
      const text = view && selection && !selection.empty
        ? view.state.doc.textBetween(selection.from, selection.to, '\n', '')
        : '';
      bridge.send({ type: 'editorSelection', payload: { requestId, text } });
      return;
    }

    if (message.type === 'pdfPaneStateChanged') {
      setPDFPaneState({
        visible: payload?.visible === true,
        streamId: typeof payload?.streamId === 'string' ? payload.streamId : undefined,
        sourceName: (payload as SourceTitlePayload | undefined)?.sourceName,
        shortTitle: (payload as SourceTitlePayload | undefined)?.shortTitle,
      });
      return;
    }

    if (message.type === 'pdfHighlightLinked') {
      if (payload?.streamId !== stream.id) return;
      const sourceId = payload.sourceId;
      const highlightId = payload.highlightId;
      if (typeof sourceId !== 'string' || typeof highlightId !== 'string') return;

      const rawPage = Number(payload.page);
      const page = Number.isFinite(rawPage) ? Math.max(1, Math.round(rawPage)) : 1;
      const sourcePayload = payload as SourceTitlePayload;
      const linkURL = buildTickerPDFLinkURL({ sourceId, highlightId, page });
      const linkLabel = `${sourcePayload.shortTitle || sourcePayload.sourceName || 'PDF'} p.${page}`;
      editorRef.current!.insertMarkdown(buildPDFQuoteSnippet({
        quote: typeof payload.quote === 'string' ? payload.quote : '',
        linkLabel,
        linkURL,
      }));
      editorRef.current!.view.focus();
      addToast('Added PDF quote to stream.', 'success');
      return;
    }

    if (message.type === 'pdfThreadRequested') {
      if (payload?.streamId !== stream.id) return;
      const sourceId = payload.sourceId;
      const highlightId = payload.highlightId;
      const quote = payload.quote;
      const rawRects = payload.rects;
      const rects = Array.isArray(rawRects) ? rawRects.flatMap((value) => {
        if (!value || typeof value !== 'object') return [];
        const rect = value as Record<string, unknown>;
        const page = Number(rect.page);
        const x = Number(rect.x);
        const y = Number(rect.y);
        const w = Number(rect.w);
        const h = Number(rect.h);
        return [page, x, y, w, h].every(Number.isFinite) ? [{ page, x, y, w, h }] : [];
      }) : [];
      if (typeof sourceId !== 'string'
          || typeof highlightId !== 'string'
          || typeof quote !== 'string'
          || !sourceId
          || !highlightId
          || !quote.trim()
          || rects.length === 0) {
        if (typeof highlightId === 'string' && highlightId) {
          bridge.send({
            type: 'deletePdfHighlight',
            payload: { streamId: stream.id, highlightId },
          });
        }
        addToast('That PDF selection could not create a Sidenote.', 'error');
        return;
      }
      void startPDFSelectionThread({
        streamId: stream.id,
        sourceId,
        highlightId,
        quote,
        sourceName: typeof payload.sourceName === 'string' ? payload.sourceName : undefined,
        shortTitle: typeof payload.shortTitle === 'string' ? payload.shortTitle : undefined,
        page: Number.isFinite(Number(payload.page)) ? Number(payload.page) : rects[0].page,
        createdAt: typeof payload.createdAt === 'string' ? payload.createdAt : new Date().toISOString(),
        rects,
      });
      return;
    }

    if (message.type === 'pdfHighlightDeleted') {
      if (payload?.streamId !== stream.id) return;
      const highlightId = payload.highlightId;
      if (typeof highlightId !== 'string') return;
      removePDFHighlightLink(editorRef.current!.view, highlightId);
      addToast('Removed PDF link.', 'success');
      return;
    }

    if (message.type === 'revealPdfHighlightInStream') {
      if (payload?.streamId !== stream.id) return;
      const sourceId = payload.sourceId;
      const highlightId = payload.highlightId;
      if (typeof sourceId !== 'string' || typeof highlightId !== 'string') return;
      if (!revealPDFHighlight(editorRef.current!.view, sourceId, highlightId)) {
        void openPDFHighlightThread(sourceId, highlightId);
        return;
      }
      addToast('Showing linked highlight in stream.', 'success');
      return;
    }

    if (message.type === 'pdfAnchorPickCancelled') {
      if (payload?.streamId === stream.id) pendingPDFAnchorSelectionRef.current = null;
      return;
    }

    if (message.type === 'pdfAnchorPlaced') {
      if (payload?.streamId !== stream.id) return;
      const pending = pendingPDFAnchorSelectionRef.current;
      pendingPDFAnchorSelectionRef.current = null;
      if (!pending) return;

      const sourceId = payload.sourceId;
      const highlightId = payload.highlightId;
      if (typeof sourceId !== 'string' || typeof highlightId !== 'string') return;

      const view = editorRef.current!.view;
      const rawPage = Number(payload.page);
      const page = Number.isFinite(rawPage) ? Math.max(1, Math.round(rawPage)) : 1;
      const href = buildTickerPDFLinkURL({ sourceId, highlightId, page });
      const link = view.state.schema.marks.link.create({ href, title: null });
      const tr = view.state.tr.addMark(pending.from, pending.to, link);
      tr.setSelection(TextSelection.create(tr.doc, pending.from, pending.to));
      view.dispatch(tr.scrollIntoView());
      view.focus();
      addToast('Anchored selection in PDF.', 'success');
      return;
    }

    if (message.type === 'pdfSectionActionRequested') {
      const request = parsePDFSectionActionRequest(payload, stream.id);
      if (!request) return;
      if (request.action === 'summarize') {
        startPDFSectionAI(request);
        return;
      }
      if (!canStartAI()) return;
      setPromptValue('');
      setPromptIntent({ kind: 'pdfSection', request });
      return;
    }

    const activeAI = aiRequestRef.current;

    if (message.type === 'aiOperationChanged') {
      if (payload?.streamId === stream.id && payload.origin === 'pdfSection') {
        if (
          payload.state === 'succeeded'
          || payload.state === 'failed'
          || payload.state === 'canceled'
        ) {
          pdfAIInFlightRef.current = false;
        }
        return;
      }
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const detail = typeof payload.message === 'string' ? payload.message : payload.state;
      if (typeof detail === 'string') setAIDetail(`AI ${detail}`);
      return;
    }

    if (message.type === 'documentModelSelected') {
      if (!activeAI || payload?.requestId !== activeAI.requestId || typeof payload.modelId !== 'string') return;
      activeAI.model = payload.modelId;
      setAIDetail(`AI model: ${payload.modelId}`);
      return;
    }

    if (message.type === 'documentAIChunk') {
      if (!activeAI || payload?.requestId !== activeAI.requestId || typeof payload.chunk !== 'string' || !payload.chunk) return;
      activeAI.stream.push(payload.chunk);
      return;
    }

    if (message.type === 'documentAIError') {
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const cancelled = payload.errorCode === 'cancelled';
      const error = typeof payload.error === 'string' ? payload.error : 'AI request failed.';
      cancelDocumentAI(false);
      if (!cancelled) addToast(error, 'error');
      return;
    }

    if (message.type === 'documentAIComplete') {
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const rawOutput = activeAI.stream.markdown.trim();
      if (!rawOutput) {
        // The chunks have already replaced the target, so accepting an empty
        // buffer here permanently deletes the text the request was meant to edit.
        cancelDocumentAI(false);
        addToast('AI returned empty output.', 'error');
        return;
      }

      const { view } = activeAI.editor;

      const citations = parseDocumentAICitations(payload.citations);
      let finalOutput = rawOutput;
      let provenanceLine: string | null = null;
      if (citations) {
        const result = swapCitationMarkersWithMetadata(rawOutput, citations);
        finalOutput = result.text;
        provenanceLine = buildProvenanceLine(result.swappedCitations);
      } else if (payload.sourceContextMode === 'none') {
        provenanceLine = '*From model knowledge.*';
      } else if (payload.sourceContextMode === 'unavailable') {
        provenanceLine = '*Source retrieval unavailable — answered from model knowledge.*';
      }
      if (provenanceLine) finalOutput = `${finalOutput}\n\n${provenanceLine}`;

      // The citation pass has to join the stream's history event. Otherwise Undo
      // stops on the raw provider markers instead of restoring the user's text.
      activeAI.stream.finalize(finalOutput);
      const written = activeAI.stream.done();
      const span = {
        spanId: crypto.randomUUID(),
        ...written,
        origin: 'ai' as const,
        requestId: activeAI.requestId,
        meta: { model: activeAI.model ?? null, verb: activeAI.verb },
        textHash: hashProvenanceText(view.state.doc, written),
        createdAt: Date.now(),
      };
      const tr = addProvenanceSpans(setAIWritingRange(view.state.tr, null), [span])
        .setMeta('addToHistory', false);
      view.dispatch(tr);

      aiRequestRef.current = null;
      aiInFlightRef.current = false;
      setAIRunning(false);
      setAIDetail(null);
      setSourceIndexNotice(null);
      session.documentChanged();
      return;
    }

    if (message.type === 'streamDocumentAppended') {
      session.documentAppended({
        streamId: String(payload?.streamId ?? ''),
        fragment: String(payload?.fragment ?? ''),
        revision: Number(payload?.revision),
        // Offsets into the fragment's own markdown, which is all the host can know
        // without parsing the document. Not forwarding them — which is what this
        // did — dropped the provenance of everything the AI and the quick panel
        // wrote while the stream was open.
        spans: payload?.spans as ProvenanceSpanJSON[] | undefined,
      });
      if (payload?.streamId === stream.id && payload.source === 'pdfSectionAI') {
        pdfAIInFlightRef.current = false;
      }
      return;
    }

    if (message.type === 'streamAppendInboxChanged') {
      session.documentInboxChanged({
        streamId: String(payload?.streamId ?? ''),
        appendInbox: Array.isArray(payload?.appendInbox)
          ? payload.appendInbox as StreamAppendInboxJSON[]
          : [],
      });
      return;
    }

    if (message.type === 'streamDocumentConflict') {
      cancelDocumentAI();
      const conflict = payload as Partial<StreamDocumentConflictPayload> | undefined;
      session.documentConflict({
        streamId: String(conflict?.streamId ?? ''),
        docJSON: conflict?.docJSON,
        docFormatVersion: conflict?.docFormatVersion,
        markdown: String(conflict?.markdown ?? ''),
        revision: Number(conflict?.revision),
        spans: conflict?.spans?.map(spanFromJSON),
        pendingAppends: decodePendingAppends(
          Array.isArray(conflict?.pendingAppends) ? conflict.pendingAppends : [],
        ),
        inboxAppends: Array.isArray(conflict?.appendInbox) ? conflict.appendInbox : [],
      });
      return;
    }

    if (message.type === 'flushEditor') {
      // The host is closing or quitting and waits for this before it does. It is
      // acknowledged either way — leaving the host hung is worse than a failed save
      // it can see — but a failure still shows as an error and raises a toast.
      const requestId = payload?.requestId;
      if (typeof requestId !== 'string') return;
      void flushAll().then((saved) => {
        // Reported truthfully: the host cancels quitting on a false, because
        // closing over an editor that could not save discards the only copy.
        bridge.send({
          type: 'editorFlushed',
          payload: { requestId, saved },
        });
      });
    }
  }), [
    addToast,
    canStartAI,
    cancelDocumentAI,
    flushAll,
    openPDFHighlightThread,
    startPDFSelectionThread,
    startPDFSectionAI,
    stream.id,
  ]);

  /**
   * A reload this session asked for, after an append it could not reconcile.
   *
   * It arrives as new props rather than as a message: App already decodes
   * streamLoaded — including the request-id check that stops a stale response
   * being applied — and the stream id does not change, so React keeps this
   * component mounted and nothing else would apply the document. Reading the
   * decoded props avoids a second decoder that can disagree with the first, which
   * is exactly what happened: the payload nests under `stream`, and a handler
   * reading `payload.document` returned early every time.
   */
  useEffect(() => {
    const session = sessionRef.current;
    const document = stream.document;
    if (!session || !document) return;
    if (document.revision <= session.currentRevision) return;
    cancelDocumentAI();
    session.documentLoaded({
      docJSON: document.docJSON,
      docFormatVersion: document.docFormatVersion,
      markdown: document.markdown,
      revision: document.revision,
      spans: (stream.spans ?? []).map(spanFromJSON),
      // The reloaded document brings its own rows. Without them the session could
      // never let the store forget another one, and a row that outlives the
      // revision it was recorded at can never be replayed.
      pendingAppends: decodePendingAppends(stream.pendingAppends),
      inboxAppends: stream.appendInbox ?? [],
    });
  }, [
    cancelDocumentAI,
    stream.appendInbox,
    stream.document,
    stream.pendingAppends,
    stream.spans,
  ]);

  const startEditingTitle = useCallback(() => {
    setIsEditingTitle(true);
    setTimeout(() => titleInputRef.current?.select(), 0);
  }, []);

  const saveTitle = useCallback(() => {
    const next = title.trim() || 'Untitled';
    setTitle(next);
    setIsEditingTitle(false);
    if (next !== stream.title) {
      bridge.send({ type: 'updateStreamTitle', payload: { id: stream.id, title: next } });
    }
  }, [stream.id, stream.title, title]);

  const handleTitleKeyDown = useCallback((event: ReactKeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      saveTitle();
    } else if (event.key === 'Escape') {
      setTitle(stream.title);
      setIsEditingTitle(false);
    }
  }, [saveTitle, stream.title]);

  const run = (command: Command) => () => {
    if (!editor) return;
    const scroller = editor.view.dom.closest('.stream-content');
    const scrollTop = scroller?.scrollTop;
    command(editor.view.state, editor.view.dispatch, editor.view);
    editor.view.focus();
    if (scroller && scrollTop !== undefined) {
      scroller.scrollTop = scrollTop;
      window.requestAnimationFrame(() => { scroller.scrollTop = scrollTop; });
    }
  };

  const formats = editor ? activeFormats(editor.view.state) : null;
  const activePDFHighlight = editor ? selectedPDFHighlight(editor.view.state) : null;
  const sourceScopeLabel = sourceScope === 'all' ? 'All' : sourceScope === 'none' ? 'None' : 'Auto';
  const openPDFTitle = pdfPaneState.visible && pdfPaneState.streamId === stream.id
    ? pdfPaneState.shortTitle ?? pdfPaneState.sourceName ?? 'Open PDF'
    : null;
  const canAnchorSelection = Boolean(
    editor
    && openPDFTitle
    && !activePDFHighlight
    && editor.view.state.doc.textBetween(
      editor.view.state.selection.from,
      editor.view.state.selection.to,
      '\n',
      '',
    ).trim(),
  );
  const documentAIActions = [
    {
      key: 'develop',
      label: 'Develop',
      ariaLabel: 'Develop with AI',
      title: 'Develop the selection with AI',
      disabled: aiRunning || threadAIRunning,
      action: () => { void startDocumentAI(); },
    },
    {
      key: 'prompt',
      label: 'Ask about…',
      ariaLabel: 'Ask about selection with AI',
      disabled: aiRunning || threadAIRunning,
      action: () => openDocumentAIPrompt('ask'),
    },
    {
      key: 'ask',
      label: 'Ask',
      ariaLabel: 'Ask with AI',
      disabled: aiRunning || threadAIRunning,
      action: () => { void startDocumentAI('ask'); },
    },
    {
      key: 'define',
      label: 'Define',
      ariaLabel: 'Define with AI',
      disabled: aiRunning || threadAIRunning,
      action: () => { void startDocumentAI('define'); },
    },
    {
      key: 'rewrite',
      label: 'Rewrite…',
      ariaLabel: 'Rewrite with AI',
      disabled: aiRunning || threadAIRunning,
      action: () => openDocumentAIPrompt('rewrite'),
    },
  ];

  const promoteSidenote = async (request: SidenotePromotionRequest): Promise<boolean> => {
    const currentEditor = editorRef.current;
    const session = sessionRef.current;
    if (!currentEditor || !session || threadInsertionSaveFailed) {
      addToast('Retry the unsaved Stream change before adding another.', 'info');
      return false;
    }
    const { view } = currentEditor;
    const requestedAnchorSpanId = 'anchorSpanId' in request.target ? request.target.anchorSpanId : null;
    const anchorSpan = requestedAnchorSpanId
      ? provenanceSpans(view.state).find((span) => span.spanId === requestedAnchorSpanId)
      : null;
    if (requestedAnchorSpanId && !anchorSpan) {
      addToast('That Stream quote was removed. Choose the Stream cursor instead.', 'warning');
      return false;
    }
    const target = request.target.kind === 'replaceAnchor'
      ? { kind: 'replace' as const, from: anchorSpan!.from, to: anchorSpan!.to }
      : request.target.kind === 'afterAnchor'
        ? sidenoteInsertionTarget(view.state, anchorSpan!.from)
        : request.target.kind === 'cursor'
          ? sidenoteInsertionTarget(view.state, view.state.selection.head)
          : { kind: 'block' as const, pos: view.state.doc.content.size };
    if (!target) {
      addToast('Place the Stream cursor in a text block, then try again.', 'info');
      return false;
    }

    let inserted: ReturnType<typeof insertSidenoteWork>;
    try {
      inserted = insertSidenoteWork(view, target, request);
    } catch {
      addToast('That Sidenote passage could not be added here.', 'error');
      return false;
    }
    const placementSpanId = crypto.randomUUID();
    view.dispatch(addProvenanceSpans(view.state.tr, [{
      spanId: placementSpanId,
      from: inserted.from,
      to: inserted.to,
      origin: 'thread',
      meta: { threadId: request.threadId, placement: true },
      textHash: hashProvenanceText(view.state.doc, inserted),
      createdAt: Date.now(),
    }]));
    const anchorId = crypto.randomUUID();
    if (!await session.saveNow()) {
      pendingSidenotePlacementRef.current = { threadId: request.threadId, anchorId, anchorSpanId: placementSpanId };
      setThreadInsertionSaveFailed(request.threadId);
      return false;
    }
    setThreadInsertionSaveFailed(null);
    try {
      const result = await addStreamThreadAnchor({
        streamId: stream.id,
        threadId: request.threadId,
        anchor: { anchorId, kind: 'placement', anchorSpanId: placementSpanId },
      });
      rememberSidenoteAnchor(request.threadId, result.anchor);
      await threadDrawerRef.current?.addAnchor(result.anchor);
    } catch {
      addToast('The text is saved, but its Sidenote marker could not be recorded.', 'warning');
    }
    const revealed = inserted.blockPositions
      .map((pos) => view.nodeDOM(pos))
      .map((node) => (node instanceof Element ? node : node?.parentElement))
      .filter((node): node is Element => Boolean(node));
    revealed.forEach((node) => node.classList.add('sidenote-promotion-reveal'));
    window.setTimeout(() => revealed.forEach((node) => node.classList.remove('sidenote-promotion-reveal')), 1_200);
    return true;
  };

  const startStreamSidenote = async () => {
    const requestEditor = editorRef.current;
    if (!requestEditor || threadCreateInFlightRef.current) return;
    if (!await (threadDrawerRef.current?.flush() ?? Promise.resolve(true))) {
      setShowThreads(true);
      addToast('Resolve the open Sidenote before adding another quote.', 'error');
      return;
    }

    const { from, to } = requestEditor.view.state.selection;
    const anchorText = requestEditor.view.state.doc.textBetween(from, to, '\n', '');
    if (!anchorText.trim()) return;

    const anchorSpanId = crypto.randomUUID();
    const threadId = activeSidenote?.threadId ?? crypto.randomUUID();
    const anchorId = crypto.randomUUID();
    const createdAt = new Date().toISOString();
    const anchor: StreamThreadAnchorJSON = {
      anchorId,
      threadId,
      kind: 'stream_quote',
      quote: anchorText,
      anchorSpanId,
      createdAt,
    };
    pendingThreadAnchorSelectionRef.current = { from, to };
    threadCreateInFlightRef.current = true;
    setThreadCreating(true);
    hideSelectionMenu();

    try {
      const result = activeSidenote
        ? await addStreamThreadAnchor({
          streamId: stream.id,
          threadId,
          anchor: {
            anchorId,
            kind: 'stream_quote',
            quote: anchorText,
            anchorSpanId,
            createdAt,
          },
        })
        : await createStreamThread({
          streamId: stream.id,
          threadId,
          title: defaultThreadTitle(anchorText),
          workingText: '',
          docJSON: buildSidenoteDocumentJSON([anchor]),
          docFormatVersion: 1,
          anchorText,
          anchorSpanId,
          anchors: [{
            anchorId,
            kind: 'stream_quote',
            quote: anchorText,
            anchorSpanId,
            createdAt,
          }],
        });
      const thread = 'thread' in result ? result.thread : activeSidenote!;
      const savedAnchor = 'anchor' in result ? result.anchor : anchor;
      if (!activeSidenote) rememberSidenote(thread);
      const pending = pendingThreadAnchorSelectionRef.current;
      pendingThreadAnchorSelectionRef.current = null;
      if (editorRef.current !== requestEditor) return;

      if (pending
          && requestEditor.view.state.doc.textBetween(pending.from, pending.to, '\n', '') === anchorText) {
        const span = {
          spanId: anchorSpanId,
          from: pending.from,
          to: pending.to,
          origin: 'thread' as const,
          meta: { threadId: thread.threadId },
          textHash: hashProvenanceText(requestEditor.view.state.doc, pending),
          createdAt: Date.now(),
        };
        const tr = addProvenanceSpans(requestEditor.view.state.tr, [span]);
        tr.setSelection(TextSelection.near(tr.doc.resolve(pending.to)));
        requestEditor.view.dispatch(tr);
        sessionRef.current?.documentChanged();
      }

      setShowThreads(true);
      if (activeSidenote) {
        if (!await threadDrawerRef.current?.addAnchor(savedAnchor)) {
          addToast('The quote is attached, but the Sidenote still needs to save.', 'warning');
        } else {
          addToast('Added the Stream quote to this Sidenote.', 'success');
        }
      } else if (!await threadDrawerRef.current?.showThread(thread)) {
        addToast('The Sidenote was created, but another draft needs attention before it can open.', 'error');
      } else {
        addToast('Created a Sidenote from the Stream quote.', 'success');
      }
    } catch {
      pendingThreadAnchorSelectionRef.current = null;
      addToast('The Sidenote quote could not be added.', 'error');
    } finally {
      threadCreateInFlightRef.current = false;
      setThreadCreating(false);
    }
  };

  const startPDFAnchorPick = () => {
    const { from, to } = editor!.view.state.selection;
    pendingPDFAnchorSelectionRef.current = { from, to };
    beginPDFAnchorPick(stream.id);
  };

  const formatButton = (label: string, active: boolean, command: Command, hint: string) => (
    <button
      key={label}
      type="button"
      className={[
        'selection-action-button',
        'selection-action-button--format',
        label === 'I' ? 'selection-action-button--italic' : '',
        label === 'U' ? 'selection-action-button--underline' : '',
        label === 'Code' ? 'selection-action-button--code selection-action-button--text' : '',
        label.length > 2 && label !== 'Code' ? 'selection-action-button--text' : '',
        active ? 'selection-action-button--active' : '',
      ].filter(Boolean).join(' ')}
      title={hint}
      aria-label={hint}
      // Keep the selection: the editor must not lose focus to the button.
      onMouseDown={(event) => event.preventDefault()}
      onClick={run(command)}
    >
      {label}
    </button>
  );

  return (
    <div
      className="stream-editor"
      onPointerDownCapture={(event) => {
        const menu = streamOverflowMenuRef.current;
        if (menu?.open && !menu.contains(event.target as Node)) menu.open = false;
        if (markerChooser
            && !markerChooserRef.current?.contains(event.target as Node)
            && !(event.target as Element).closest?.('.sidenote-marker')) {
          setMarkerChooser(null);
        }
      }}
      onKeyDownCapture={(event) => {
        if (event.key === 'Escape' && streamOverflowMenuRef.current?.open) {
          streamOverflowMenuRef.current.open = false;
        }
      }}
    >
      <header className="stream-header">
        <button onClick={leave} disabled={leaving} className="back-button">← Back</button>
        {isEditingTitle ? (
          <input
            ref={titleInputRef}
            type="text"
            className="stream-title-input"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            onBlur={saveTitle}
            onKeyDown={handleTitleKeyDown}
            autoFocus
          />
        ) : (
          <h1 onClick={startEditingTitle} className="stream-title-editable" title={title}>
            {title}
          </h1>
        )}
        <div className="stream-header-actions">
          {saveState !== 'saved' && (
            <span
              className={`stream-save-status stream-save-status--${saveState}`}
              role="status"
              aria-live="polite"
              aria-label={SAVE_LABEL[saveState]}
              title={SAVE_LABEL[saveState]}
            >
              <span className="stream-save-status-dot" aria-hidden="true" />
              <span className="stream-save-status-label">{SAVE_LABEL[saveState]}</span>
            </span>
          )}
          <button
            onClick={() => setXray((value) => !value)}
            className={`stream-xray-button ${xray ? 'stream-xray-button--active' : ''}`}
            title={xray ? 'Hide where text came from' : 'Show where text came from'}
            type="button"
            aria-label={xray ? 'Hide where text came from' : 'Show where text came from'}
            aria-pressed={xray}
          >
            <EyeIcon size={16} />
          </button>
          {sidenotes.length > 0 && (
            <button
              ref={threadButtonRef}
              type="button"
              className={`stream-threads-button ${showThreads ? 'stream-threads-button--active' : ''}`}
              aria-label={`Sidenotes, ${sidenotes.length}`}
              aria-pressed={showThreads}
              title="Sidenotes"
              onClick={() => {
                if (showThreads) void threadDrawerRef.current?.close();
                else setShowThreads(true);
              }}
            >
              Sidenotes · {sidenotes.length}
            </button>
          )}
          <button
            type="button"
            className="stream-sources-button"
            aria-label={`Sources, ${sources.length} ${sources.length === 1 ? 'source' : 'sources'}`}
            title="Sources"
            onClick={() => setShowSourcesModal(true)}
          >
            {sources.length > 0 ? `Sources · ${sources.length}` : 'Sources'}
          </button>
          <details
            ref={streamOverflowMenuRef}
            className="stream-overflow-menu"
            onBlur={(event) => {
              if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget)) {
                event.currentTarget.open = false;
              }
            }}
            onKeyDown={(event) => {
              if (event.key !== 'Escape') return;
              event.preventDefault();
              event.currentTarget.open = false;
              event.currentTarget.querySelector('summary')?.focus();
            }}
          >
            <summary title="More stream actions" aria-label="More stream actions">
              <span aria-hidden="true">•••</span>
            </summary>
            <div className="stream-overflow-panel">
              <button
                type="button"
                className="stream-overflow-delete"
                onClick={() => {
                  streamOverflowMenuRef.current!.open = false;
                  setShowDeleteConfirm(true);
                }}
              >
                Delete stream…
              </button>
            </div>
          </details>
        </div>
      </header>

      {showDeleteConfirm && (
        <Modal
          className="delete-confirm-dialog"
          aria-labelledby="richtext-delete-confirm-title"
          onRequestClose={() => setShowDeleteConfirm(false)}
        >
          <h2 id="richtext-delete-confirm-title">Delete this stream?</h2>
          <p>This will permanently delete "{title}" and all its contents. This cannot be undone.</p>
          <div className="delete-confirm-actions">
            <button
              className="delete-confirm-cancel"
              onClick={() => setShowDeleteConfirm(false)}
            >
              Cancel
            </button>
            <button
              className="delete-confirm-delete"
              onClick={() => {
                setShowDeleteConfirm(false);
                remove();
              }}
            >
              Delete
            </button>
          </div>
        </Modal>
      )}

      {promptIntent && (
        <Modal
          className="ai-prompt-dialog"
          aria-labelledby="richtext-ai-prompt-title"
          onRequestClose={closeDocumentAIPrompt}
        >
          <h2 id="richtext-ai-prompt-title">
            {promptIntent.kind === 'pdfSection'
              ? 'Ask this section'
              : promptIntent.verb === 'rewrite' ? 'Rewrite' : 'Ask about selection'}
          </h2>
          <p>
            {promptIntent.kind === 'pdfSection'
              ? `“${promptIntent.request.sectionTitle}” from ${promptIntent.request.shortTitle} will be attached as context.`
              : 'The selected text will be attached as context.'}
          </p>
          <textarea
            className="ai-prompt-input"
            value={promptValue}
            onChange={(event) => setPromptValue(event.target.value)}
            onKeyDown={(event) => {
              if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
                event.preventDefault();
                sendDocumentAIPrompt();
              } else if (event.key === 'Escape') {
                event.preventDefault();
                closeDocumentAIPrompt();
              }
            }}
            placeholder={promptIntent.kind === 'pdfSection'
              ? 'Ask about this section…'
              : promptIntent.verb === 'rewrite'
                ? 'How should this be rewritten?'
                : 'Ask a question or give an instruction…'}
            autoFocus
            maxLength={promptIntent.kind === 'pdfSection' ? 32_000 : undefined}
            rows={5}
          />
          <div className="ai-prompt-actions">
            <button
              className="ai-prompt-cancel"
              type="button"
              onClick={closeDocumentAIPrompt}
            >
              Cancel
            </button>
            <button
              className="ai-prompt-send"
              type="button"
              aria-label={promptIntent.kind === 'pdfSection'
                ? 'Ask PDF section'
                : promptIntent.verb === 'rewrite' ? 'Rewrite with prompt' : 'Ask AI'}
              onClick={sendDocumentAIPrompt}
              disabled={!promptValue.trim()}
            >
              {promptIntent.kind === 'pdfSection'
                ? 'Ask section'
                : promptIntent.verb === 'rewrite' ? 'Rewrite' : 'Ask'}
            </button>
          </div>
        </Modal>
      )}

      {exchangeOverlay && (
        <ExchangeOverlay
          exchange={exchangeOverlay}
          onClose={() => setExchangeOverlay(null)}
          onOpenManifestEntry={openExchangeManifestEntry}
        />
      )}

      {markerChooser && (
        <div
          ref={markerChooserRef}
          className="sidenote-marker-chooser"
          role="menu"
          aria-label="Choose a Sidenote"
          style={{ left: `${markerChooser.left}px`, top: `${markerChooser.top}px` }}
          onBlur={(event) => {
            if (!event.relatedTarget || !event.currentTarget.contains(event.relatedTarget)) {
              setMarkerChooser(null);
            }
          }}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.preventDefault();
              setMarkerChooser(null);
              return;
            }
            if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
            event.preventDefault();
            const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button')];
            const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
            const step = event.key === 'ArrowDown' ? 1 : -1;
            buttons[(index + step + buttons.length) % buttons.length]?.focus();
          }}
        >
          {markerChooser.threadIds.map((threadId) => {
            const thread = sidenotes.find((candidate) => candidate.threadId === threadId);
            return (
              <button
                key={threadId}
                type="button"
                role="menuitem"
                onClick={() => {
                  setMarkerChooser(null);
                  setShowThreads(true);
                  void threadDrawerRef.current?.openThread(threadId);
                }}
              >
                <strong>{thread?.title || 'Untitled Sidenote'}</strong>
                <span>{thread ? sidenoteSourceLabel(thread) : 'Stream'}</span>
              </button>
            );
          })}
        </div>
      )}

      {formats && selectionMenu.visible && (
        <div
          ref={selectionActionMenuRef}
          className="selection-action-menu"
          style={{ left: `${selectionMenu.left}px`, top: `${selectionMenu.top}px` }}
        >
          <div className="selection-action-row">
            {formatButton('B', formats.bold, toggleBold, 'Bold ⌘B')}
            {formatButton('I', formats.italic, toggleItalic, 'Italic ⌘I')}
            {formatButton('U', formats.underline, toggleUnderline, 'Underline ⌘U')}
            <button
              type="button"
              className="selection-action-button selection-action-button--text selection-action-button--thread"
              aria-label={activeSidenote ? 'Add quote to Sidenote' : 'New Sidenote'}
              disabled={threadCreating}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => { void startStreamSidenote(); }}
            >
              {activeSidenote ? 'Add quote' : 'New Sidenote'}
            </button>
            <div className="selection-action-submenu">
              <button
                type="button"
                className="selection-action-button selection-action-button--text selection-action-button--ai"
                title="AI actions"
                aria-label="AI actions"
                aria-expanded={selectionMenuPanel === 'ai'}
                disabled={aiRunning || threadAIRunning}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => setSelectionMenuPanel((panel) => panel === 'ai' ? null : 'ai')}
              >
                AI ▾
              </button>
            </div>
            <div className="selection-action-submenu">
              <button
                type="button"
                className="selection-action-button selection-action-button--text"
                title="More formatting and context actions"
                aria-label="More actions"
                aria-expanded={selectionMenuPanel === 'more'}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => setSelectionMenuPanel((panel) => panel === 'more' ? null : 'more')}
              >
                More ▾
              </button>
            </div>
            {canAnchorSelection && (
              <button
                type="button"
                className="selection-action-button selection-action-button--text"
                aria-label="Anchor selection in PDF"
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => {
                  hideSelectionMenu();
                  startPDFAnchorPick();
                }}
              >
                Anchor PDF
              </button>
            )}
            {activePDFHighlight && (
              <button
                type="button"
                className="selection-action-button selection-action-button--text"
                aria-label="Remove PDF link"
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => {
                  hideSelectionMenu();
                  bridge.send({
                    type: 'deletePdfHighlight',
                    payload: {
                      streamId: stream.id,
                      highlightId: activePDFHighlight.highlightId,
                    },
                  });
                }}
              >
                Remove PDF
              </button>
            )}
          </div>
          {selectionMenuPanel === 'ai' && (
            <div className="selection-action-submenu-panel">
              {documentAIActions.map((action) => (
                <button
                  key={action.key}
                  type="button"
                  className="selection-action-button selection-action-button--text selection-action-button--wide selection-action-button--ai"
                  aria-label={action.ariaLabel}
                  title={action.title}
                  disabled={action.disabled}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => {
                    hideSelectionMenu();
                    action.action();
                  }}
                >
                  {action.label}
                </button>
              ))}
            </div>
          )}
          {selectionMenuPanel === 'more' && (
            <div className="selection-action-submenu-panel" aria-label="More formatting and context actions">
              {formatButton('Code', formats.code, toggleCode, 'Code')}
              <span className="selection-action-group-label">Paragraph</span>
              {formatButton('H1', formats.heading === 1, toggleHeading(1), 'Heading 1')}
              {formatButton('H2', formats.heading === 2, toggleHeading(2), 'Heading 2')}
              {formatButton('H3', formats.heading === 3, toggleHeading(3), 'Heading 3')}
              {formatButton('List', formats.bulletList, toggleBulletList, 'Bullets')}
              {formatButton('1.', formats.orderedList, toggleOrderedList, 'Numbers')}
              {formatButton('Quote', formats.blockquote, toggleBlockquote, 'Quote')}
              <button
                type="button"
                className="selection-action-button selection-action-button--text selection-action-button--wide selection-action-source-scope"
                aria-label="Cycle source scope"
                title="Cycle source scope"
                onMouseDown={(event) => event.preventDefault()}
                onClick={cycleSourceScope}
              >
                Sources: {sourceScopeLabel}
              </button>
            </div>
          )}
        </div>
      )}

      <div className="stream-body">
        <div className="stream-content">
          <div
            ref={editorShellRef}
            className={`document-editor-shell ${xray ? 'richtext-xray' : ''}`}
          >
            <div ref={host} />
            {aiRunning && (
              <div
                className="document-ai-status-pill"
                role="status"
                aria-live="polite"
              >
                <span className="document-ai-status-dot" aria-hidden="true" />
                <span>{aiDetail ?? 'AI is writing'}</span>
                <button
                  type="button"
                  className="document-ai-stop-button"
                  aria-label="Stop document AI"
                  title={aiDetail ?? 'Stop document AI'}
                  onClick={() => cancelDocumentAI()}
                >
                  <XIcon size={12} /> Stop
                </button>
              </div>
            )}
            {aiRunning && sourceIndexNotice && (
              <div className="document-ai-indexing-notice" role="status" aria-live="polite">
                {sourceIndexNotice}
              </div>
            )}
          </div>
        </div>
        <ThreadDrawer
          ref={threadDrawerRef}
          streamId={stream.id}
          isOpen={showThreads}
          onRequestClose={() => setShowThreads(false)}
          onAfterClose={() => threadButtonRef.current?.focus()}
          onLocateAnchor={locateThreadAnchor}
          onActiveThreadChange={setActiveSidenote}
          onThreadsChange={rememberSidenotes}
          onSidenoteUpdated={rememberSidenote}
          onSidenoteDeleted={removeSidenoteMarkers}
          sourceScope={sourceScope}
          onBeginAI={beginThreadAI}
          onEndAI={endThreadAI}
          onOpenPDFDestination={openLink}
          onPromote={promoteSidenote}
          streamSaveErrorThreadId={threadInsertionSaveFailed}
          onRetryStreamSave={() => { void retryThreadInsertionSave(); }}
        />
      </div>

      <SourcesModal
        isOpen={showSourcesModal}
        streamId={stream.id}
        sources={sources}
        onClose={() => setShowSourcesModal(false)}
        onSourceRemoved={removeSource}
        onSourceAIExclusionChanged={setSourceAIExclusion}
        onSourceOpen={openSource}
        highlightedSourceId={highlightedSourceId}
        onClearHighlight={() => setHighlightedSourceId(null)}
      />
    </div>
  );
}
