import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react';
import { createPortal } from 'react-dom';
import type { Slice } from 'prosemirror-model';
import { TextSelection, type Command, type Transaction } from 'prosemirror-state';
import {
  bridge,
  createStreamThread,
  deleteEphemeralThread,
  deleteStreamThread,
  getExchange,
  listConversations,
  saveStreamThread,
  type DocumentAIVerb,
  type SourceTitlePayload,
  type StreamDocumentConflictPayload,
} from '../types/bridge';
import type {
  AIExchangeJSON,
  ConversationAnchorJSON,
  SourceReference,
  SourceScope,
  Stream,
  StreamAppendInboxJSON,
  StreamThreadJSON,
} from '../types/models';
import {
  ConversationSurface,
  initialConversationLiveState,
  type ConversationLiveState,
} from './ConversationSurface';
import { ExchangeOverlay, type ExchangeManifestEntry } from './ExchangeOverlay';
import { EyeIcon, XIcon } from './icons';
import { Modal } from './Modal';
import { SourcesModal } from './SourcesModal';
import {
  nextSourceScope,
  parsePDFSectionActionRequest,
  type PDFSectionActionRequest,
} from './StreamEditor';
import { createRichTextEditor, type RichTextEditor } from '../richtext/editor';
import { parseTickerPDFURL } from '../extensions/PDFHighlightLink';
import {
  conversationAnchorFromJSON,
  conversationAnchorText,
  conversationAnchorTextForStorage,
  conversationAnchors,
  conversationRenderPosition,
  conversationSurfacePosition,
  conversationSurface,
  fullBlockConversationAnchor,
  hasConversationAnchorTextDrifted,
  refreshConversationViewport,
  setConversationAnchors,
  setConversationSurface,
  type ConversationAnchor,
} from '../richtext/conversationAnchors';
import {
  aiWritingRange,
  insertImage,
  insertMarkdownBlocks,
  pdfHighlightRange,
  promoteConversationMarkdown,
  removePDFHighlightLink,
  revealPDFHighlight,
  selectedPDFHighlight,
  selectText,
  setAIWritingRange,
  streamAIMarkdown,
} from '../richtext/operations';
import { DocumentSession, type SaveState } from '../richtext/session';
import {
  addProvenanceSpans,
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
import { formatRelativeTime } from '../utils/relativeTime';
import { manifestCitations } from '../threads/context';
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
  sourceId?: string;
  sourceName?: string;
  shortTitle?: string;
  selection?: {
    highlightId: string;
    page: number;
    quote: string;
    createdAt: string;
    rects: Array<{ page: number; x: number; y: number; w: number; h: number }>;
  };
}

interface SelectionMenuState {
  visible: boolean;
  left: number;
  top: number;
  from: number;
  to: number;
}

interface ExpandedConversation {
  key: string;
  threadId?: string;
  anchor?: ConversationAnchor;
  renderAt?: number;
  anchorText: string;
  focusComposer: boolean;
  ephemeral?: boolean;
  profile?: 'research';
}

type SlashCommand = 'chat' | 'research';

interface SlashMenuState {
  left: number;
  top: number;
  selected: number;
}

const SLASH_COMMANDS: Array<{ command: SlashCommand; description: string }> = [
  { command: 'chat', description: 'think out loud, saved only if you keep it' },
  { command: 'research', description: 'ask with sources and web search' },
];

function slashCommandInput(view: RichTextEditor['view']) {
  const { selection } = view.state;
  const { $head } = selection;
  if (!selection.empty || $head.depth !== 1 || $head.parent.type.name !== 'paragraph') return null;
  const text = $head.parent.textContent;
  if ($head.parentOffset !== text.length) return null;
  const match = /^\/([a-z]*)(?:\s(.*))?$/.exec(text);
  if (!match) return null;
  const commandName = match[1];
  if (commandName && !SLASH_COMMANDS.some(({ command }) => command.startsWith(commandName))) return null;
  return {
    from: $head.before(),
    to: $head.after(),
    commandName,
    draft: match[2] ?? '',
  };
}

type ConversationLiveStateUpdater = (current: ConversationLiveState) => ConversationLiveState;

function documentAITarget(editor: RichTextEditor): { from: number; to: number; text: string } | null {
  const { doc, selection } = editor.view.state;
  const from = selection.empty ? selection.$head.start() : selection.from;
  const to = selection.empty ? selection.$head.end() : selection.to;
  const text = doc.textBetween(from, to, '\n', '').trim();
  return text ? { from, to, text } : null;
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
  const lastEditorCursorRef = useRef<number | null>(null);
  const titleInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const streamOverflowMenuRef = useRef<HTMLDetailsElement>(null);
  const selectionActionMenuRef = useRef<HTMLDivElement>(null);
  // ponytail: one stream-wide PDF AI lock; track host operation ids if concurrent
  // PDF jobs ever become a supported workflow.
  const pdfAIInFlightRef = useRef(false);
  const consumedPendingSourceRef = useRef<string | null>(null);
  const conversationRecordsRef = useRef<ConversationAnchorJSON[]>(
    (stream.conversationAnchors ?? []).filter((record) => !record.ephemeral),
  );
  const expandedConversationRef = useRef<ExpandedConversation | null>(null);
  const conversationLiveStatesRef = useRef<Record<string, ConversationLiveState>>({});
  const conversationCollapseTimerRef = useRef<number>();
  const conversationCreatePromisesRef = useRef(new Map<string, Promise<StreamThreadJSON>>());
  const conversationKeepPromisesRef = useRef(new Map<string, Promise<boolean>>());
  const closingConversationKeysRef = useRef(new Set<string>());
  const slashArmedRef = useRef(false);
  const slashMenuRef = useRef<SlashMenuState | null>(null);

  const [editor, setEditor] = useState<RichTextEditor | null>(null);
  const [saveState, setSaveState] = useState<SaveState>('saved');
  const [showSaving, setShowSaving] = useState(false);
  const wasSaving = useRef(false);
  const [headerScrolled, setHeaderScrolled] = useState(false);
  const [aiRunning, setAIRunning] = useState(false);
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
  const [editorVersion, redraw] = useState(0);
  const [expandedConversation, setExpandedConversation] = useState<ExpandedConversation | null>(null);
  const [conversationLiveStates, setConversationLiveStates] = useState<Record<string, ConversationLiveState>>({});
  const [conversationWidgetTarget, setConversationWidgetTarget] = useState<HTMLElement | null>(null);
  const [conversationRecords, setConversationRecords] = useState<ConversationAnchorJSON[]>(
    (stream.conversationAnchors ?? []).filter((record) => !record.ephemeral),
  );
  const [showConversationList, setShowConversationList] = useState(false);
  const [conversationListLoading, setConversationListLoading] = useState(false);
  const [conversationListError, setConversationListError] = useState(false);
  const [conversationPendingDelete, setConversationPendingDelete] = useState<ConversationAnchorJSON | null>(null);
  const [slashMenu, setSlashMenu] = useState<SlashMenuState | null>(null);
  slashMenuRef.current = slashMenu;
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

  useEffect(() => {
    if (saveState === 'saving') {
      wasSaving.current = true;
      setShowSaving(true);
      return;
    }
    if (saveState === 'error') {
      wasSaving.current = false;
      setShowSaving(false);
      return;
    }
    if (!wasSaving.current) return;
    wasSaving.current = false;
    const timer = window.setTimeout(() => setShowSaving(false), 800);
    return () => window.clearTimeout(timer);
  }, [saveState]);

  const canStartAI = useCallback(() => {
    if (!aiInFlightRef.current && !pdfAIInFlightRef.current) return true;
    addToast('Wait for the current AI operation to finish, or stop it first.', 'info');
    return false;
  }, [addToast]);

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

  const updateConversationLiveState = useCallback((
    key: string,
    updater: ConversationLiveStateUpdater,
  ) => {
    const current = conversationLiveStatesRef.current;
    const value = updater(current[key] ?? initialConversationLiveState());
    if (value === current[key]) return;
    const next = { ...current, [key]: value };
    conversationLiveStatesRef.current = next;
    setConversationLiveStates(next);
  }, []);

  const ensureConversationLiveState = useCallback((key: string, threadId?: string) => {
    const current = conversationLiveStatesRef.current;
    if (current[key]) return;
    const next = { ...current, [key]: initialConversationLiveState(threadId) };
    conversationLiveStatesRef.current = next;
    setConversationLiveStates(next);
  }, []);

  const cancelConversationRequest = useCallback((key: string, updateUI = true) => {
    const current = conversationLiveStatesRef.current[key];
    if (!current?.active?.running) return;
    bridge.send({ type: 'cancelDocumentAI', payload: { requestId: current.active.requestId } });
    const stopped = {
      ...current,
      active: { ...current.active, running: false, error: 'Stopped.' },
    };
    const next = { ...conversationLiveStatesRef.current, [key]: stopped };
    conversationLiveStatesRef.current = next;
    if (updateUI) setConversationLiveStates(next);
  }, []);

  const discardEphemeralConversation = useCallback(async (key: string): Promise<boolean> => {
    await conversationKeepPromisesRef.current.get(key);
    try {
      await conversationCreatePromisesRef.current.get(key);
    } catch {
      // Creation reports its own error; there is no row left to discard.
    }
    const thread = conversationLiveStatesRef.current[key]?.thread;
    if (!thread?.ephemeral) return true;
    try {
      await deleteEphemeralThread({ streamId: stream.id, threadId: thread.threadId });
      const records = conversationRecordsRef.current.filter((record) => record.threadId !== thread.threadId);
      conversationRecordsRef.current = records;
      setConversationRecords(records);
      updateConversationLiveState(key, (current) => ({
        ...current,
        thread: null,
        exchanges: [],
        active: null,
      }));
      return true;
    } catch {
      updateConversationLiveState(key, (current) => ({
        ...current,
        error: 'This chat could not be discarded.',
      }));
      return false;
    }
  }, [stream.id, updateConversationLiveState]);

  const keepExpandedConversation = useCallback((): Promise<boolean> => {
    const expanded = expandedConversationRef.current;
    if (!expanded?.ephemeral) return Promise.resolve(true);
    const pending = conversationKeepPromisesRef.current.get(expanded.key);
    if (pending) return pending;
    const task = (async () => {
      updateConversationLiveState(expanded.key, (state) => ({ ...state, keeping: true }));
      try {
        try {
          await conversationCreatePromisesRef.current.get(expanded.key);
        } catch {
          // A failed creation leaves this as an unsent draft, which can still be kept.
        }
        let thread = conversationLiveStatesRef.current[expanded.key]?.thread;
        if (thread) {
          const saved = await saveStreamThread({
            streamId: stream.id,
            threadId: thread.threadId,
            title: thread.title,
            baseRevision: thread.revision,
            ephemeral: false,
          });
          thread = saved.thread;
          if (thread.ephemeral) throw new Error('Keep conflicted');
          updateConversationLiveState(expanded.key, (state) => ({ ...state, thread }));
        }
        const currentExpanded = expandedConversationRef.current;
        if (currentExpanded?.key === expanded.key) {
          const kept = { ...currentExpanded, ephemeral: false };
          expandedConversationRef.current = kept;
          setExpandedConversation(kept);
        }
        const liveEditor = editorRef.current;
        const surface = liveEditor && conversationSurface(liveEditor.view.state);
        if (thread && liveEditor && surface?.key === expanded.key) {
          const anchor = { ...surface.anchor, threadId: thread.threadId };
          liveEditor.view.dispatch(setConversationAnchors(liveEditor.view.state.tr, [
            ...conversationAnchors(liveEditor.view.state)
              .filter((candidate) => candidate.threadId !== thread!.threadId),
            anchor,
          ]));
          const records = [
            ...conversationRecordsRef.current.filter((record) => record.threadId !== thread!.threadId),
            {
              threadId: thread.threadId,
              anchorStart: anchor.from,
              anchorEnd: anchor.to,
              anchorText: thread.anchorText,
              detached: anchor.from >= anchor.to,
              ephemeral: false,
              updatedAt: thread.updatedAt,
            },
          ];
          conversationRecordsRef.current = records;
          setConversationRecords(records);
          sessionRef.current?.documentChanged();
        }
        return true;
      } catch {
        updateConversationLiveState(expanded.key, (state) => ({
          ...state,
          error: 'This chat could not be kept.',
        }));
        return false;
      } finally {
        conversationKeepPromisesRef.current.delete(expanded.key);
        updateConversationLiveState(expanded.key, (state) => ({ ...state, keeping: false }));
      }
    })();
    conversationKeepPromisesRef.current.set(expanded.key, task);
    return task;
  }, [stream.id, updateConversationLiveState]);

  const discardExpandedEphemeralConversation = useCallback(async (): Promise<boolean> => {
    const expanded = expandedConversationRef.current;
    return expanded?.ephemeral ? discardEphemeralConversation(expanded.key) : true;
  }, [discardEphemeralConversation]);

  const flushAll = useCallback(async () => {
    cancelDocumentAI();
    const expanded = expandedConversationRef.current;
    if (expanded) {
      closingConversationKeysRef.current.add(expanded.key);
      cancelConversationRequest(expanded.key);
      await discardExpandedEphemeralConversation();
      closingConversationKeysRef.current.delete(expanded.key);
    }
    return sessionRef.current?.saveNow() ?? Promise.resolve(true);
  }, [cancelConversationRequest, cancelDocumentAI, discardExpandedEphemeralConversation]);

  useEffect(() => {
    onFlushAvailable?.(flushAll);
    return () => onFlushAvailable?.(null);
  }, [flushAll, onFlushAvailable]);

  const prepareConversationClose = useCallback(async (expanded: ExpandedConversation) => {
    closingConversationKeysRef.current.add(expanded.key);
    cancelConversationRequest(expanded.key);
    updateConversationLiveState(expanded.key, (state) => ({ ...state, closing: true }));
    const discarded = expanded.ephemeral !== true
      || await discardEphemeralConversation(expanded.key);
    closingConversationKeysRef.current.delete(expanded.key);
    if (!discarded) {
      updateConversationLiveState(expanded.key, (state) => ({ ...state, closing: false }));
    }
    return discarded;
  }, [cancelConversationRequest, discardEphemeralConversation, updateConversationLiveState]);

  const expandConversation = useCallback(async (next: ExpandedConversation) => {
    const current = expandedConversationRef.current;
    if (current?.key !== next.key) {
      if (current && !await prepareConversationClose(current)) return;
      if (current) updateConversationLiveState(current.key, (state) => ({ ...state, closing: false }));
      ensureConversationLiveState(next.key, next.threadId);
    }
    if (conversationCollapseTimerRef.current !== undefined) {
      window.clearTimeout(conversationCollapseTimerRef.current);
      conversationCollapseTimerRef.current = undefined;
    }
    expandedConversationRef.current = next;
    setExpandedConversation(next);
  }, [ensureConversationLiveState, prepareConversationClose, updateConversationLiveState]);

  const collapseConversation = useCallback(async () => {
    const expanded = expandedConversationRef.current;
    if (!expanded || conversationCollapseTimerRef.current !== undefined) return;
    const currentEditor = editorRef.current;
    const anchor = currentEditor && conversationSurface(currentEditor.view.state)?.anchor;
    if (!await prepareConversationClose(expanded)) return;
    conversationCollapseTimerRef.current = window.setTimeout(() => {
      conversationCollapseTimerRef.current = undefined;
      if (expandedConversationRef.current?.key !== expanded.key) return;
      expandedConversationRef.current = null;
      setExpandedConversation(null);
      setConversationWidgetTarget(null);
      updateConversationLiveState(expanded.key, (state) => ({ ...state, closing: false }));
      if (!currentEditor || !anchor) return;
      window.requestAnimationFrame(() => {
        if (currentEditor.view.isDestroyed) return;
        const pos = Math.max(0, Math.min(anchor.from, currentEditor.view.state.doc.content.size));
        currentEditor.view.dispatch(currentEditor.view.state.tr.setSelection(
          TextSelection.near(currentEditor.view.state.doc.resolve(pos)),
        ));
        currentEditor.view.focus();
      });
    }, 150);
  }, [prepareConversationClose, updateConversationLiveState]);

  useEffect(() => () => {
    if (conversationCollapseTimerRef.current !== undefined) {
      window.clearTimeout(conversationCollapseTimerRef.current);
    }
    for (const key of Object.keys(conversationLiveStatesRef.current)) {
      cancelConversationRequest(key, false);
    }
    const expanded = expandedConversationRef.current;
    if (expanded) closingConversationKeysRef.current.add(expanded.key);
    const thread = expanded && conversationLiveStatesRef.current[expanded.key]?.thread;
    if (expanded?.ephemeral && thread?.ephemeral) {
      void deleteEphemeralThread({ streamId: stream.id, threadId: thread.threadId }).catch(() => undefined);
    }
  }, [cancelConversationRequest, stream.id]);

  const openConversationFromGlyph = useCallback((threadId: string) => {
    const view = editorRef.current?.view;
    const anchor = view && conversationAnchors(view.state).find((candidate) => candidate.threadId === threadId);
    if (!anchor) return;
    const record = conversationRecordsRef.current.find((candidate) => candidate.threadId === threadId);
    expandConversation({
      key: `thread:${threadId}`,
      threadId,
      anchorText: record?.anchorText ?? '',
      focusComposer: false,
    });
  }, [expandConversation]);

  const revealPDFConversation = useCallback((sourceId: string, highlightId: string) => {
    const view = editorRef.current?.view;
    if (!view) return false;
    const range = pdfHighlightRange(view.state, sourceId, highlightId);
    if (!range || !revealPDFHighlight(view, sourceId, highlightId)) return false;
    const anchor = conversationAnchors(view.state).find((candidate) => (
      range.from < candidate.to && range.to > candidate.from
    ));
    if (anchor) openConversationFromGlyph(anchor.threadId);
    return true;
  }, [openConversationFromGlyph]);

  const createConversationAtBlock = useCallback((anchor: ConversationAnchor) => {
    const view = editorRef.current?.view;
    if (!view) return;
    const open = conversationSurface(view.state);
    if (open && conversationRenderPosition(view.state.doc, open.anchor)
      === conversationRenderPosition(view.state.doc, anchor)) {
      collapseConversation();
      return;
    }
    const key = `draft:${crypto.randomUUID()}`;
    const draft = { ...anchor, threadId: key };
    expandConversation({
      key,
      anchor: draft,
      anchorText: conversationAnchorTextForStorage(view.state.doc, draft),
      focusComposer: true,
    });
  }, [collapseConversation, expandConversation]);

  const updateSlashMenu = useCallback(() => {
    if (!slashArmedRef.current && !slashMenuRef.current) return;
    const view = editorRef.current?.view;
    const input = view && slashCommandInput(view);
    if (!view || !input) {
      slashArmedRef.current = false;
      if (slashMenuRef.current) {
        slashMenuRef.current = null;
        setSlashMenu(null);
      }
      return;
    }
    slashArmedRef.current = false;
    let coords = { left: 0, bottom: 0 };
    try {
      coords = view.coordsAtPos(view.state.selection.head);
    } catch {
      // jsdom and first WebKit layout can have no caret rectangle yet.
    }
    const matched = input.commandName
      ? SLASH_COMMANDS.findIndex(({ command }) => command.startsWith(input.commandName))
      : -1;
    const next = {
      left: coords.left,
      top: coords.bottom + 6,
      selected: matched >= 0 ? matched : slashMenuRef.current?.selected ?? 0,
    };
    slashMenuRef.current = next;
    setSlashMenu(next);
  }, []);

  const runSlashCommand = useCallback((command: SlashCommand) => {
    const view = editorRef.current?.view;
    const input = view && slashCommandInput(view);
    if (!view || !input) return;
    const key = `slash:${crypto.randomUUID()}`;
    const previous = input.from > 0
      ? fullBlockConversationAnchor(view.state.doc, input.from - 1, key)
      : null;
    view.dispatch(view.state.tr.delete(input.from, input.to).setMeta('addToHistory', false));
    const anchor = previous ?? {
      threadId: key,
      from: view.state.doc.content.size,
      to: view.state.doc.content.size,
      detached: true,
    };
    slashMenuRef.current = null;
    setSlashMenu(null);
    updateConversationLiveState(key, (current) => ({ ...current, composer: input.draft }));
    expandConversation({
      key,
      anchor,
      renderAt: anchor.detached ? view.state.doc.content.size : undefined,
      anchorText: conversationAnchorTextForStorage(view.state.doc, anchor),
      focusComposer: true,
      ephemeral: command === 'chat',
      profile: command === 'research' ? 'research' : undefined,
    });
  }, [expandConversation, updateConversationLiveState]);

  // Which formatting buttons are lit depends on the SELECTION, so the menu has to
  // redraw on every transaction and not only on edits.
  const onUpdate = useCallback(() => {
    redraw((n) => n + 1);
    updateSelectionMenu();
    updateSlashMenu();
    if (editorRef.current) refreshConversationViewport(editorRef.current.view);
  }, [updateSelectionMenu, updateSlashMenu]);

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
    if (transaction.selectionSet) lastEditorCursorRef.current = transaction.selection.head;
    else if (transaction.docChanged && lastEditorCursorRef.current !== null) {
      lastEditorCursorRef.current = transaction.mapping.map(lastEditorCursorRef.current, 1);
    }
  }, []);

  /**
   * A citation is not an external URL. Swift rejects any non-HTTP scheme from
   * openExternalURL, so routing `ticker-pdf://` there did nothing at all — the
   * click was simply swallowed. Citations go to the PDF pane instead.
   */
  const openLink = useCallback((href: string) => {
    if (href.startsWith(PDF_URL_PREFIX)) {
      bridge.send({ type: 'openPdfDestination', payload: { streamId: stream.id, url: href } });
      const destination = parseTickerPDFURL(href);
      if (destination?.sourceId && destination.highlightId) {
        revealPDFConversation(destination.sourceId, destination.highlightId);
      }
      return;
    }
    bridge.send({ type: 'openExternalURL', payload: { url: href } });
  }, [revealPDFConversation, stream.id]);

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
        conversations: {
          onCreate: createConversationAtBlock,
          onOpen: openConversationFromGlyph,
        },
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
      conversationAnchors: (stream.conversationAnchors ?? [])
        .filter((record) => !record.ephemeral)
        .map(conversationAnchorFromJSON),
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
          conversationAnchors,
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
            conversationAnchors,
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
      refreshConversationViewport(created.view);
      window.clearTimeout(scrollSaveTimer);
      scrollSaveTimer = window.setTimeout(() => {
        scrollSaveTimer = undefined;
        sendScrollPosition();
      }, 1_000);
    };
    scroller.scrollTop = Math.max(0, stream.document?.scrollOffset ?? 0);
    scroller.addEventListener('scroll', saveScrollPosition, { passive: true });
    refreshConversationViewport(created.view);

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
  }, [
    addToast,
    createConversationAtBlock,
    onTransaction,
    onUpdate,
    openConversationFromGlyph,
    openLink,
    stream.id,
    updateSelectionMenu,
  ]);

  useEffect(() => {
    const records = (stream.conversationAnchors ?? []).filter((record) => !record.ephemeral);
    conversationRecordsRef.current = records;
    setConversationRecords(records);
  }, [stream.conversationAnchors]);

  const persistConversation = useCallback(async (
    currentSurface: { key: string; anchor: ConversationAnchor },
    title: string,
    pdf?: { sourceId: string; highlightId: string },
    ephemeral = false,
    profile?: 'research',
  ): Promise<StreamThreadJSON> => {
    const currentEditor = editorRef.current;
    if (!currentEditor) throw new Error('Conversation closed');
    const anchorText = conversationAnchorTextForStorage(currentEditor.view.state.doc, currentSurface.anchor);
    if (!anchorText && !currentSurface.anchor.detached) throw new Error('Anchor deleted');
    const { thread } = await createStreamThread({
      streamId: stream.id,
      title,
      anchorStart: currentSurface.anchor.from,
      anchorEnd: currentSurface.anchor.to,
      anchorText,
      sourceId: pdf?.sourceId,
      highlightId: pdf?.highlightId,
      detached: currentSurface.anchor.detached,
      ephemeral,
      profile,
    });

    const liveEditor = editorRef.current;
    if (!liveEditor || liveEditor.view.isDestroyed) return thread;
    const liveSurface = conversationSurface(liveEditor.view.state);
    const mapped = liveSurface?.key === currentSurface.key
      ? liveSurface.anchor
      : conversationAnchors(liveEditor.view.state)
        .find((anchor) => anchor.threadId === currentSurface.anchor.threadId)
        ?? currentSurface.anchor;
    const persisted = { ...mapped, threadId: thread.threadId, detached: mapped.from >= mapped.to };
    const anchors = conversationAnchors(liveEditor.view.state)
      .filter((anchor) => anchor.threadId !== thread.threadId
        && anchor.threadId !== currentSurface.anchor.threadId);
    if (!thread.ephemeral) {
      liveEditor.view.dispatch(setConversationAnchors(liveEditor.view.state.tr, [...anchors, persisted]));
    }
    if (liveSurface?.key === currentSurface.key) {
      liveEditor.view.dispatch(setConversationSurface(liveEditor.view.state.tr, {
        key: currentSurface.key,
        anchor: persisted,
      }));
      const expanded = expandedConversationRef.current;
      if (expanded?.key === currentSurface.key) {
        const next = { ...expanded, threadId: thread.threadId, anchor: undefined };
        expandedConversationRef.current = next;
        setExpandedConversation(next);
      }
    }
    if (!thread.ephemeral) {
      const records = [
        ...conversationRecordsRef.current.filter((record) => record.threadId !== thread.threadId),
        {
          threadId: thread.threadId,
          anchorStart: persisted.from,
          anchorEnd: persisted.to,
          anchorText,
          detached: persisted.detached,
          ephemeral: false,
          updatedAt: thread.updatedAt,
        },
      ];
      conversationRecordsRef.current = records;
      setConversationRecords(records);
      sessionRef.current?.documentChanged();
    }
    return thread;
  }, [stream.id]);

  const createPersistedConversation = useCallback(async (
    query: string,
    ephemeral: boolean,
    profile?: 'research',
  ): Promise<StreamThreadJSON> => {
    const currentEditor = editorRef.current;
    const currentSurface = currentEditor && conversationSurface(currentEditor.view.state);
    if (!currentSurface) throw new Error('Conversation closed');
    const key = currentSurface.key;
    let task: Promise<StreamThreadJSON>;
    task = persistConversation(
      currentSurface,
      query.split(/\r?\n/, 1)[0],
      undefined,
      ephemeral,
      profile,
    ).then(async (thread) => {
      if (closingConversationKeysRef.current.has(key)) {
        if (thread.ephemeral) {
          await deleteEphemeralThread({ streamId: stream.id, threadId: thread.threadId });
        }
        throw new Error('Conversation closed');
      }
      updateConversationLiveState(key, (state) => ({ ...state, thread }));
      return thread;
    }).finally(() => {
      if (conversationCreatePromisesRef.current.get(key) === task) {
        conversationCreatePromisesRef.current.delete(key);
      }
    });
    conversationCreatePromisesRef.current.set(key, task);
    return task;
  }, [persistConversation, stream.id, updateConversationLiveState]);

  const conversationHasDrifted = useCallback((anchorText: string) => {
    const currentEditor = editorRef.current;
    const surface = currentEditor && conversationSurface(currentEditor.view.state);
    return !currentEditor || !surface || hasConversationAnchorTextDrifted(
      currentEditor.view.state.doc,
      surface.anchor,
      anchorText,
    );
  }, []);

  const promoteConversationTurn = useCallback(async (exchange: AIExchangeJSON) => {
    if (expandedConversationRef.current?.ephemeral && !await keepExpandedConversation()) return;
    const currentEditor = editorRef.current;
    const surface = currentEditor && conversationSurface(currentEditor.view.state);
    if (!currentEditor || !surface) return;
    try {
      const priorPromotionEnd = provenanceSpans(currentEditor.view.state)
        .filter((span) => span.origin === 'ai' && span.meta.threadId === surface.anchor.threadId)
        .reduce((end, span) => Math.max(end, span.to), 0);
      const inserted = promoteConversationMarkdown(
        currentEditor.view,
        priorPromotionEnd || conversationSurfacePosition(currentEditor.view.state.doc, surface.anchor)
          || currentEditor.view.state.doc.content.size,
        swapCitationMarkersWithMetadata(
          exchange.responseRaw,
          manifestCitations(exchange.sourceManifest),
        ).text,
        {
          requestId: exchange.requestId,
          model: exchange.model,
          verb: exchange.verb,
          threadId: surface.anchor.threadId,
        },
      );
      window.setTimeout(() => {
        if (currentEditor.view.isDestroyed) return;
        const highlighted = aiWritingRange(currentEditor.view.state);
        if (highlighted?.from !== inserted.from || highlighted.to !== inserted.to) return;
        currentEditor.view.dispatch(
          setAIWritingRange(currentEditor.view.state.tr, null).setMeta('addToHistory', false),
        );
      }, 1_200);
      addToast('Added to the Stream.', 'success');
    } catch {
      addToast("Couldn't add the reply.", 'error');
    }
  }, [addToast, keepExpandedConversation]);

  const discardPDFQuote = useCallback((streamId: unknown, highlightId: unknown) => {
    if (typeof highlightId === 'string') {
      bridge.send({
        type: 'deletePdfHighlight',
        payload: { streamId: typeof streamId === 'string' ? streamId : stream.id, highlightId },
      });
    }
    addToast("Couldn't add the quote", 'info');
  }, [addToast, stream.id]);

  const quoteAndDiscussPDF = useCallback(async (selection: {
    streamId: string;
    sourceId: string;
    sourceName: string;
    shortTitle: string;
    highlightId: string;
    page: number;
    quote: string;
  }) => {
    const currentEditor = editorRef.current;
    const session = sessionRef.current;
    if (!currentEditor || !session) {
      discardPDFQuote(selection.streamId, selection.highlightId);
      return;
    }
    const { view } = currentEditor;
    let key: string | undefined;
    try {
      const cursor = lastEditorCursorRef.current;
      const cursorAnchor = cursor === null
        ? null
        : fullBlockConversationAnchor(view.state.doc, cursor, '');
      const insertAt = cursorAnchor
        ? conversationSurfacePosition(view.state.doc, cursorAnchor) ?? view.state.doc.content.size
        : view.state.doc.content.size;
      const linkURL = buildTickerPDFLinkURL(selection);
      const inserted = insertMarkdownBlocks(view, insertAt, buildPDFQuoteSnippet({
        quote: selection.quote,
        linkLabel: `${selection.shortTitle || selection.sourceName || 'PDF'} p.${selection.page}`,
        linkURL,
      }));
      key = `pdf:${crypto.randomUUID()}`;
      const anchor = fullBlockConversationAnchor(view.state.doc, inserted.from + 2, key);
      if (!anchor) throw new Error('The PDF quote could not be anchored.');
      view.dispatch(setConversationAnchors(view.state.tr, [...conversationAnchors(view.state), anchor]));
      view.dispatch(setConversationSurface(view.state.tr, { key, anchor }));
      if (!await session.saveNow()) throw new Error('The PDF quote could not be saved.');

      const thread = await persistConversation(
        { key, anchor },
        selection.quote.slice(0, 80),
        { sourceId: selection.sourceId, highlightId: selection.highlightId },
      );
      updateConversationLiveState(key, (current) => ({
        ...current,
        thread,
        exchanges: thread.exchanges ?? [],
        loading: false,
      }));
      expandConversation({
        key,
        threadId: thread.threadId,
        anchorText: thread.anchorText,
        focusComposer: true,
      });
      addToast('Added PDF quote and opened a conversation.', 'success');
    } catch {
      const liveEditor = editorRef.current;
      if (key && liveEditor && !liveEditor.view.isDestroyed) {
        liveEditor.view.dispatch(setConversationAnchors(
          liveEditor.view.state.tr,
          conversationAnchors(liveEditor.view.state).filter((item) => item.threadId !== key),
        ));
        if (conversationSurface(liveEditor.view.state)?.key === key) {
          liveEditor.view.dispatch(setConversationSurface(liveEditor.view.state.tr, null));
        }
      }
      discardPDFQuote(selection.streamId, selection.highlightId);
    }
  }, [addToast, discardPDFQuote, expandConversation, persistConversation, updateConversationLiveState]);

  const toggleConversationList = useCallback(async () => {
    if (showConversationList) {
      setShowConversationList(false);
      return;
    }
    setShowConversationList(true);
    setConversationListLoading(true);
    setConversationListError(false);
    try {
      const { conversations } = await listConversations(stream.id);
      const kept = conversations.filter((record) => !record.ephemeral);
      conversationRecordsRef.current = kept;
      setConversationRecords(kept);
    } catch {
      setConversationListError(true);
    } finally {
      setConversationListLoading(false);
    }
  }, [showConversationList, stream.id]);

  const openConversationFromList = useCallback((record: ConversationAnchorJSON) => {
    const liveEditor = editorRef.current;
    if (!liveEditor) return;
    const anchor = conversationAnchors(liveEditor.view.state)
      .find((candidate) => candidate.threadId === record.threadId);
    if (anchor && !record.detached) {
      expandConversation({
        key: `thread:${record.threadId}`,
        threadId: record.threadId,
        anchorText: record.anchorText,
        focusComposer: false,
      });
      window.requestAnimationFrame(() => {
        const target = liveEditor.view.domAtPos(anchor.from).node;
        (target instanceof Element ? target : target.parentElement)?.scrollIntoView({ block: 'center' });
      });
    } else {
      const position = liveEditor.view.state.doc.content.size;
      // ponytail: detached conversations render at document end; add archive
      // positioning only if detached browsing grows beyond this plain list.
      expandConversation({
        key: `thread:${record.threadId}`,
        threadId: record.threadId,
        anchor: { threadId: record.threadId, from: position, to: position, detached: true },
        renderAt: position,
        anchorText: record.anchorText,
        focusComposer: false,
      });
      window.requestAnimationFrame(() => liveEditor.view.dom.lastElementChild?.scrollIntoView({ block: 'center' }));
    }
    setShowConversationList(false);
    if (streamOverflowMenuRef.current) streamOverflowMenuRef.current.open = false;
  }, [expandConversation]);

  const deleteConversation = useCallback(async (record: ConversationAnchorJSON) => {
    try {
      await deleteStreamThread({ streamId: stream.id, threadId: record.threadId });
      const records = conversationRecordsRef.current
        .filter((candidate) => candidate.threadId !== record.threadId);
      conversationRecordsRef.current = records;
      setConversationRecords(records);
      const liveEditor = editorRef.current;
      const deletingOpenConversation = liveEditor
        && conversationSurface(liveEditor.view.state)?.anchor.threadId === record.threadId;
      if (liveEditor) {
        liveEditor.view.dispatch(setConversationAnchors(
          liveEditor.view.state.tr,
          conversationAnchors(liveEditor.view.state)
            .filter((anchor) => anchor.threadId !== record.threadId),
        ));
      }
      if (deletingOpenConversation) collapseConversation();
    } catch {
      addToast('This conversation could not be deleted.', 'error');
    }
  }, [addToast, collapseConversation, stream.id]);

  useLayoutEffect(() => {
    if (!editor) return;
    let surface = conversationSurface(editor.view.state);
    if (!expandedConversation) {
      if (surface) editor.view.dispatch(setConversationSurface(editor.view.state.tr, null));
      if (conversationWidgetTarget) setConversationWidgetTarget(null);
      return;
    }
    if (surface?.key !== expandedConversation.key) {
      const anchor = expandedConversation.anchor ?? conversationAnchors(editor.view.state)
        .find((candidate) => candidate.threadId === expandedConversation.threadId);
      if (!anchor) {
        setConversationWidgetTarget(null);
        return;
      }
      editor.view.dispatch(setConversationSurface(editor.view.state.tr, {
        key: expandedConversation.key,
        anchor,
        renderAt: expandedConversation.renderAt,
      }));
      surface = conversationSurface(editor.view.state);
    }
    const target = [...editor.view.dom.querySelectorAll<HTMLElement>('[data-conversation-widget]')]
      .find((candidate) => candidate.dataset.conversationWidget === surface?.key) ?? null;
    setConversationWidgetTarget((current) => current === target ? current : target);
  }, [conversationWidgetTarget, editor, editorVersion, expandedConversation]);

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
    const keydown = (event: KeyboardEvent) => {
      if (editor.view.composing) return;
      const menu = slashMenuRef.current;
      if (menu) {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault();
          const direction = event.key === 'ArrowDown' ? 1 : -1;
          const next = {
            ...menu,
            selected: (menu.selected + direction + SLASH_COMMANDS.length) % SLASH_COMMANDS.length,
          };
          slashMenuRef.current = next;
          setSlashMenu(next);
        } else if (event.key === 'Enter') {
          event.preventDefault();
          runSlashCommand(SLASH_COMMANDS[menu.selected].command);
        } else if (event.key === 'Escape') {
          event.preventDefault();
          slashMenuRef.current = null;
          setSlashMenu(null);
        }
        return;
      }
      const { selection } = editor.view.state;
      if (event.key === '/'
        && selection.empty
        && selection.$head.parent.type.name === 'paragraph'
        && selection.$head.parent.content.size === 0) {
        slashArmedRef.current = true;
      }
    };
    editor.view.dom.addEventListener('keydown', keydown, true);
    return () => editor.view.dom.removeEventListener('keydown', keydown, true);
  }, [editor, runSlashCommand]);

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
    lastEditorCursorRef.current = null;
  }, [stream.id]);

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
    const expanded = expandedConversationRef.current;
    setLeaving(true);
    if (expanded && !await prepareConversationClose(expanded)) {
      setLeaving(false);
      addToast('This chat could not be discarded, so the stream stayed open.', 'error');
      return;
    }
    const documentSaved = await (sessionRef.current?.destroy() ?? Promise.resolve(true));
    if (documentSaved) return onBack();
    setLeaving(false);
    if (expanded) {
      updateConversationLiveState(expanded.key, (state) => ({ ...state, closing: false }));
    }
    addToast('Your changes could not be saved, so this stream stayed open.', 'error');
  }, [
    addToast,
    cancelDocumentAI,
    onBack,
    prepareConversationClose,
    updateConversationLiveState,
  ]);

  const remove = useCallback(() => {
    deleting.current = true;
    onDelete();
  }, [onDelete]);

  useEffect(() => bridge.onMessage((message) => {
    const payload = message.payload as Record<string, unknown> | undefined;

    if (message.type === 'pdfThreadRequested') {
      const requestStreamId = payload?.streamId;
      const sourceId = payload?.sourceId;
      const sourceName = payload?.sourceName;
      const shortTitle = payload?.shortTitle;
      const highlightId = payload?.highlightId;
      const quote = payload?.quote;
      const page = Number(payload?.page);
      if (requestStreamId !== stream.id
        || typeof sourceId !== 'string'
        || typeof sourceName !== 'string'
        || typeof shortTitle !== 'string'
        || typeof highlightId !== 'string'
        || typeof quote !== 'string'
        || !quote.trim()
        || !Number.isInteger(page)
        || page < 1) {
        discardPDFQuote(requestStreamId, highlightId);
        return;
      }
      void quoteAndDiscussPDF({
        streamId: requestStreamId,
        sourceId,
        sourceName,
        shortTitle,
        highlightId,
        page,
        quote,
      });
      return;
    }

    const session = sessionRef.current;
    if (!session) return;

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
      const rawSelection = payload?.selection as PDFPaneState['selection'];
      setPDFPaneState({
        visible: payload?.visible === true,
        streamId: typeof payload?.streamId === 'string' ? payload.streamId : undefined,
        sourceId: typeof payload?.sourceId === 'string' ? payload.sourceId : undefined,
        sourceName: (payload as SourceTitlePayload | undefined)?.sourceName,
        shortTitle: (payload as SourceTitlePayload | undefined)?.shortTitle,
        selection: rawSelection
          && typeof rawSelection.highlightId === 'string'
          && typeof rawSelection.quote === 'string'
          && rawSelection.quote.length > 0
          && Array.isArray(rawSelection.rects)
          ? rawSelection
          : undefined,
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
      if (!revealPDFConversation(sourceId, highlightId)) {
        addToast('This PDF highlight is not linked in the Stream.', 'warning');
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
        conversationAnchors: conflict?.conversationAnchors
          ?.filter((record) => !record.ephemeral)
          .map(conversationAnchorFromJSON),
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
    discardPDFQuote,
    flushAll,
    quoteAndDiscussPDF,
    revealPDFConversation,
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
      conversationAnchors: (stream.conversationAnchors ?? [])
        .filter((record) => !record.ephemeral)
        .map(conversationAnchorFromJSON),
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
    stream.conversationAnchors,
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
  const liveConversationSurface = editor ? conversationSurface(editor.view.state) : null;
  const streamSelection = editor?.view.state.selection;
  const conversationContextOptions = [
    ...(editor && streamSelection && !streamSelection.empty
      && (!liveConversationSurface
        || streamSelection.to <= liveConversationSurface.anchor.from
        || streamSelection.from >= liveConversationSurface.anchor.to) ? [{
      kind: 'stream_quote' as const,
      quote: editor.view.state.doc.textBetween(streamSelection.from, streamSelection.to, '\n', ''),
      from: streamSelection.from,
      to: streamSelection.to,
    }] : []),
    ...(pdfPaneState.visible
      && pdfPaneState.streamId === stream.id
      && pdfPaneState.sourceId
      && pdfPaneState.selection
      && pdfPaneState.selection.highlightId !== (expandedConversation
        ? conversationLiveStates[expandedConversation.key]?.thread?.highlightId
        : undefined) ? [{
        kind: 'pdf_quote' as const,
        quote: pdfPaneState.selection.quote,
        sourceId: pdfPaneState.sourceId,
        sourceName: pdfPaneState.sourceName,
        sourceShortTitle: pdfPaneState.shortTitle,
        highlightId: pdfPaneState.selection.highlightId,
        page: pdfPaneState.selection.page,
        createdAt: pdfPaneState.selection.createdAt,
        rects: pdfPaneState.selection.rects,
      }] : []),
  ].filter((option) => option.quote.length > 0);
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
      disabled: aiRunning,
      action: () => { void startDocumentAI(); },
    },
    {
      key: 'prompt',
      label: 'Ask about…',
      ariaLabel: 'Ask about selection with AI',
      disabled: aiRunning,
      action: () => openDocumentAIPrompt('ask'),
    },
    {
      key: 'ask',
      label: 'Ask',
      ariaLabel: 'Ask with AI',
      disabled: aiRunning,
      action: () => { void startDocumentAI('ask'); },
    },
    {
      key: 'define',
      label: 'Define',
      ariaLabel: 'Define with AI',
      disabled: aiRunning,
      action: () => { void startDocumentAI('define'); },
    },
    {
      key: 'rewrite',
      label: 'Rewrite…',
      ariaLabel: 'Rewrite with AI',
      disabled: aiRunning,
      action: () => openDocumentAIPrompt('rewrite'),
    },
  ];

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
        if (slashMenuRef.current && !(event.target as Element).closest?.('.slash-command-menu')) {
          slashMenuRef.current = null;
          setSlashMenu(null);
        }
      }}
      onKeyDownCapture={(event) => {
        if (event.key === 'Escape' && streamOverflowMenuRef.current?.open) {
          streamOverflowMenuRef.current.open = false;
        }
      }}
    >
      <header className={`stream-header ${headerScrolled ? 'stream-header--scrolled' : ''}`}>
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
          {(saveState === 'error' || showSaving) && (
            <span
              className={`stream-save-status stream-save-status--${saveState === 'error' ? 'error' : saveState === 'saved' ? 'settled' : 'saving'}`}
              role="status"
              aria-live="polite"
              aria-label={saveState === 'error' ? 'Save failed' : 'Saving'}
              title={saveState === 'error' ? 'Save failed' : 'Saving…'}
            >
              <span className="stream-save-status-dot" aria-hidden="true" />
              <span className="stream-save-status-label">
                {saveState === 'error' ? 'Save failed' : 'Saving…'}
              </span>
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
            <div className={`stream-overflow-panel ${showConversationList ? 'stream-overflow-panel--conversations' : ''}`}>
              <button
                type="button"
                className="stream-overflow-action"
                aria-expanded={showConversationList}
                onClick={() => void toggleConversationList()}
              >
                Conversations
              </button>
              {showConversationList && (
                <div className="conversation-list" aria-label="Conversations">
                  {conversationListLoading && <p>Loading…</p>}
                  {conversationListError && <p>Conversations could not be loaded.</p>}
                  {!conversationListLoading && !conversationListError && conversationRecords.length === 0 && (
                    <p>No conversations yet.</p>
                  )}
                  {conversationRecords.map((record) => (
                    <div className="conversation-list-row" key={record.threadId}>
                      <button
                        type="button"
                        className="conversation-list-open"
                        onClick={() => openConversationFromList(record)}
                      >
                        <span className="conversation-list-title">
                          {record.anchorText.split(/\r?\n/, 1)[0] || 'Conversation'}
                        </span>
                        <span className="conversation-list-meta">
                          {formatRelativeTime(record.updatedAt)}{record.detached ? ' · detached' : ''}
                        </span>
                      </button>
                      <button
                        type="button"
                        className="conversation-list-delete"
                        aria-label="Delete conversation"
                        onClick={() => setConversationPendingDelete(record)}
                      >
                        Delete
                      </button>
                    </div>
                  ))}
                </div>
              )}
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

      {conversationPendingDelete && (
        <Modal
          className="delete-confirm-dialog conversation-delete-confirm-dialog"
          aria-labelledby="conversation-delete-confirm-title"
          onRequestClose={() => setConversationPendingDelete(null)}
        >
          <h2 id="conversation-delete-confirm-title">Delete this conversation?</h2>
          <p>This permanently deletes its turns. The Stream text stays unchanged.</p>
          <div className="delete-confirm-actions">
            <button
              className="delete-confirm-cancel"
              onClick={() => setConversationPendingDelete(null)}
            >
              Cancel
            </button>
            <button
              className="delete-confirm-delete conversation-delete-confirm-delete"
              onClick={() => {
                const record = conversationPendingDelete;
                setConversationPendingDelete(null);
                void deleteConversation(record);
              }}
            >
              Delete
            </button>
          </div>
        </Modal>
      )}

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

      {conversationWidgetTarget && expandedConversation && createPortal(
        <ConversationSurface
          conversationKey={expandedConversation.key}
          streamId={stream.id}
          sourceScope={sourceScope}
          threadId={expandedConversation.threadId}
          anchorText={expandedConversation.anchorText}
          primaryText={editor && liveConversationSurface
            ? conversationAnchorText(editor.view.state.doc, liveConversationSurface.anchor)
            : expandedConversation.anchorText}
          anchorStart={liveConversationSurface?.anchor.from ?? 0}
          anchorEnd={liveConversationSurface?.anchor.to ?? 0}
          streamMarkdown={editor?.getMarkdownProjection() ?? stream.document.markdown}
          contextOptions={conversationContextOptions}
          focusComposer={expandedConversation.focusComposer}
          ephemeral={expandedConversation.ephemeral === true}
          profile={expandedConversation.profile}
          state={conversationLiveStates[expandedConversation.key]
            ?? initialConversationLiveState(expandedConversation.threadId)}
          updateState={updateConversationLiveState}
          createThread={createPersistedConversation}
          hasDrifted={conversationHasDrifted}
          onPromote={promoteConversationTurn}
          onKeep={() => { void keepExpandedConversation(); }}
          onCollapse={collapseConversation}
        />,
        conversationWidgetTarget,
        expandedConversation.key,
      )}

      {slashMenu && (
        <div
          className="slash-command-menu"
          role="listbox"
          aria-label="Slash commands"
          style={{ left: `${slashMenu.left}px`, top: `${slashMenu.top}px` }}
        >
          {SLASH_COMMANDS.map((item, index) => (
            <button
              type="button"
              role="option"
              aria-selected={index === slashMenu.selected}
              className={index === slashMenu.selected ? 'slash-command-item--selected' : ''}
              key={item.command}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => runSlashCommand(item.command)}
            >
              <span>{item.command}</span> — {item.description}
            </button>
          ))}
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
            <div className="selection-action-submenu">
              <button
                type="button"
                className="selection-action-button selection-action-button--text selection-action-button--ai"
                title="AI actions"
                aria-label="AI actions"
                aria-expanded={selectionMenuPanel === 'ai'}
                disabled={aiRunning}
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
        <div
          className="stream-content"
          onScroll={(event) => setHeaderScrolled(event.currentTarget.scrollTop > 0)}
        >
          <div
            ref={editorShellRef}
            className={`document-editor-shell ${xray ? 'richtext-xray' : ''}`}
          >
            <div ref={host} />
            {aiRunning && (
              <div
                className="document-ai-status"
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
