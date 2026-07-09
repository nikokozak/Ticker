import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type FocusEvent, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { Decoration, EditorView } from '@codemirror/view';
import { RangeSetBuilder, StateEffect, StateField, Transaction, type Extension } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import { HighlightStyle, ensureSyntaxTree, syntaxHighlighting, syntaxTree } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { bridge, getExchange, readBack, updateMarginNote, type Stream, type SourceReference, type SourceScope, type DocumentAIVerb, type DocumentAICitation, type DocumentAISourceContextMode, type SourceTitlePayload, type ProvenanceSpanJSON, type AIExchangeJSON } from '../types';
import { SourcesModal } from './SourcesModal';
import { ExchangeOverlay, type ExchangeManifestEntry } from './ExchangeOverlay';
import { EyeIcon, NoteIcon, XIcon } from './icons';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';
import { AI_HISTORY_USER_EVENT, aiWritingExtension, getAiWritingRange, setAiWritingRangeEffect } from '../extensions/AIWritingState';
import { editorFindExtension } from '../extensions/EditorFindPanel';
import { markdownConcealExtension } from '../extensions/MarkdownConceal';
import { buildMarkdownImageToken, extractMarkdownImageUrls, markdownImageWidgetExtension } from '../extensions/MarkdownImageWidget';
import { buildLinkEditChange, linkInteractionExtension, type MarkdownLinkInfo } from '../extensions/LinkInteraction';
import { tickerPDFLinkExtension } from '../extensions/PDFHighlightLink';
import { addSpans, currentSpans, dissolveSpans, normalizeSpans, provenanceField, setSpans, type Span } from '../extensions/ProvenanceField';
import { canRedevelopSpan, provenanceXrayExtension } from '../extensions/ProvenanceXray';
import {
  buildPromoteMarginNoteEdit,
  currentMarginNotes,
  marginNotesExtension,
  marginNotesField,
  payloadMarginNotesForDoc,
  setMarginNotes,
  updateMarginNoteStatusEffect,
  type MarginNote,
  type MarginNoteStatus,
} from '../extensions/MarginNotes';
import { computeAppendInsertion } from '../utils/appendInsertion';
import { buildProvenanceLine, swapCitationMarkersWithMetadata } from '../utils/citationMarkers';
import { debugWarn } from '../utils/debug';
import { fnv1a } from '../utils/fnv1a';
import { deserializeProvenanceSpans, serializeProvenanceSpans } from '../utils/provenanceSpans';
import {
  beginPDFAnchorPick,
  buildPDFAnchorLinkEdit,
  buildTickerPDFLinkURL,
  mapPendingPDFAnchorSelection,
  type PendingPDFAnchorSelection,
} from '../utils/pdfAnchorSelection';
import { toggleInlineMark } from '../utils/inlineMarks';
import { computeSelectionMenuPlacement } from '../utils/selectionMenuPlacement';

interface StreamEditorProps {
  stream: Stream;
  onBack: () => void;
  onDelete: () => void;
  pendingCellId?: string | null;
  pendingSourceId?: string | null;
  onClearPendingCell?: () => void;
  onClearPendingSource?: () => void;
}

interface SelectionContext {
  text: string;
  from: number;
  to: number;
  imageUrls: string[];
}

type PromptIntent = {
  kind: 'ask';
} | {
  kind: 'redevelop';
  verb: DocumentAIVerb;
  parentRequestId?: string;
  preview: string;
};

type ReadBackScope = 'viewport' | 'section' | 'document';

interface ExchangeOverlayState {
  exchange: AIExchangeJSON;
  span: Span;
}

interface FloatingMenuState {
  visible: boolean;
  left: number;
  top: number;
  selectionFrom: number;
  selectionTo: number;
  selectionHead: number;
  menuWidth?: number;
  menuHeight?: number;
}

interface LinkPopoverState {
  visible: boolean;
  left: number;
  top: number;
  from: number;
  to: number;
  labelFrom: number;
  label: string;
  url: string;
  menuWidth?: number;
  menuHeight?: number;
}

interface AiFeedbackState {
  visible: boolean;
  kind: 'writing' | 'error';
  message: string;
}

interface PDFPaneState {
  visible: boolean;
  streamId?: string;
  sourceId?: string;
  sourceName?: string;
  shortTitle?: string;
}

const SELECTION_MENU_DELAY_MS = 180;
const AI_ERROR_FEEDBACK_MS = 2200;
const AI_INDEXING_NOTICE_MS = 4000;

export function nextSourceScope(scope: SourceScope): SourceScope {
  switch (scope) {
    case 'auto':
      return 'all';
    case 'all':
      return 'none';
    case 'none':
      return 'auto';
    default:
      return 'auto';
  }
}

function formatSourceScope(scope: SourceScope): string {
  switch (scope) {
    case 'all':
      return 'All';
    case 'none':
      return 'None';
    case 'auto':
    default:
      return 'Auto';
  }
}

export function wrapChallengeOutput(text: string): string {
  // Challenge renders inline-quoted until margin notes ship (Roadmap 4 P7); then it becomes a margin note. ponytail: inline placement is the ceiling here.
  const quoted = text.trim().split(/\r?\n/).map((line) => `> ${line}`).join('\n');
  return `${quoted}\n\n*— Challenge*`;
}

export function documentAIErrorRecovery(originalText: string, errorCode: string | undefined) {
  return {
    restoreText: originalText,
    silent: errorCode === 'cancelled',
  };
}

export function buildDocumentAIProvenanceSpan(options: {
  requestId: string;
  start: number;
  text: string;
  verb: DocumentAIVerb;
  model?: string;
  parentRequestId?: string;
  spanId?: string;
  createdAt?: number;
}): Span {
  const meta: Record<string, unknown> = {
    model: options.model ?? null,
    verb: options.verb,
  };
  if (options.parentRequestId) meta.parentRequestId = options.parentRequestId;

  return {
    spanId: options.spanId ?? crypto.randomUUID(),
    start: options.start,
    end: options.start + options.text.length,
    origin: 'ai',
    requestId: options.requestId,
    meta,
    textHash: fnv1a(options.text),
    createdAt: options.createdAt ?? Date.now(),
  };
}

function parseDocumentAICitations(value: unknown): DocumentAICitation[] | null {
  if (!Array.isArray(value)) return null;

  return value.flatMap((item): DocumentAICitation[] => {
    if (!item || typeof item !== 'object') return [];
    const candidate = item as Record<string, unknown>;
    const n = Number(candidate.n);
    const page = Number(candidate.page);
    const chunkId = typeof candidate.chunkId === 'string' ? candidate.chunkId : '';
    const sourceId = typeof candidate.sourceId === 'string' ? candidate.sourceId : '';
    const shortTitle = typeof candidate.shortTitle === 'string' ? candidate.shortTitle : '';
    if (!Number.isInteger(n) || n <= 0) return [];
    if (!Number.isInteger(page) || page <= 0) return [];
    if (!chunkId || !sourceId || !shortTitle) return [];
    return [{ n, page, chunkId, sourceId, shortTitle }];
  });
}

function parseDocumentAISourceContextMode(value: unknown): DocumentAISourceContextMode | undefined {
  if (value === 'passthrough' || value === 'retrieved' || value === 'none') {
    return value;
  }
  return undefined;
}

function focusEditorAtDocumentEnd(view: EditorView) {
  const end = view.state.doc.length;
  view.dispatch({
    selection: { anchor: end },
    effects: EditorView.scrollIntoView(end, { y: 'nearest' }),
    userEvent: 'select',
  });
  view.focus();
}

function restoreViewportEnd(view: EditorView, scrollOffset: number): number {
  const docLength = view.state.doc.length;
  if (docLength === 0 || scrollOffset <= 0) return view.viewport.to;

  const scrollHeight = view.scrollDOM.scrollHeight;
  const clientHeight = view.scrollDOM.clientHeight;
  if (scrollHeight <= clientHeight) return view.viewport.to;

  // ponytail: pixel-to-doc estimate; upgrade to measured CodeMirror mapping if deep restores ever flash.
  const ratio = Math.min(1, (scrollOffset + clientHeight) / scrollHeight);
  return Math.max(view.viewport.to, Math.min(docLength, Math.ceil(docLength * ratio)));
}

function isHeadingNode(name: string): boolean {
  return /^ATXHeading\d+$/.test(name) || /^SetextHeading\d*$/.test(name);
}

function sectionRangeForCursor(view: EditorView): { from: number; to: number } {
  const doc = view.state.doc;
  const cursor = view.state.selection.main.head;
  const tree = ensureSyntaxTree(view.state, doc.length, 50) ?? syntaxTree(view.state);
  const headings: number[] = [];

  tree.iterate({
    enter: (node) => {
      if (isHeadingNode(node.name)) {
        headings.push(doc.lineAt(node.from).from);
      }
    },
  });

  if (headings.length === 0) return { from: 0, to: doc.length };

  let from = 0;
  let to = doc.length;
  for (const heading of headings) {
    if (heading <= cursor) {
      from = heading;
    } else {
      to = heading;
      break;
    }
  }
  return { from, to };
}

function readBackRangeForScope(view: EditorView, scope: ReadBackScope): { from: number; to: number } {
  if (scope === 'document') return { from: 0, to: view.state.doc.length };
  if (scope === 'section') return sectionRangeForCursor(view);

  if (view.visibleRanges.length === 0) return { from: view.viewport.from, to: view.viewport.to };
  return {
    from: Math.min(...view.visibleRanges.map((range) => range.from)),
    to: Math.max(...view.visibleRanges.map((range) => range.to)),
  };
}

const clickToDocumentEndExtension: Extension = EditorView.domEventHandlers({
  mousedown: (event, view) => {
    if (event.button !== 0 || event.defaultPrevented) return false;
    if (!(event.target instanceof Node) || !view.scrollDOM.contains(event.target)) return false;

    const endCoords = view.coordsAtPos(view.state.doc.length, 1);
    if (!endCoords) return false;

    const scrollerRect = view.scrollDOM.getBoundingClientRect();
    const isBelowLastLine = event.clientY > endCoords.bottom + 6 && event.clientY <= scrollerRect.bottom;
    if (!isBelowLastLine) return false;

    event.preventDefault();
    focusEditorAtDocumentEnd(view);
    return true;
  },
});

function dispatchAiRangeClear(view: EditorView) {
  view.dispatch({
    effects: setAiWritingRangeEffect.of(null),
    annotations: Transaction.addToHistory.of(false),
  });
}

function parseSpanMeta(meta: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(meta);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

function payloadSpanToFieldSpan(span: ProvenanceSpanJSON, doc: string): Span | null {
  if (span.start < 0 || span.end <= span.start || span.end > doc.length) return null;
  const coveredText = doc.slice(span.start, span.end);
  if (fnv1a(coveredText) !== span.textHash) return null;
  const createdAt = Date.parse(span.createdAt);
  if (!Number.isFinite(createdAt)) return null;
  const origin = span.origin === 'ai' || span.origin === 'source' || span.origin === 'capture'
    ? span.origin
    : null;
  if (!origin) return null;

  return {
    spanId: span.spanId,
    start: span.start,
    end: span.end,
    origin,
    requestId: span.requestId,
    sourceId: span.sourceId,
    meta: parseSpanMeta(span.meta),
    textHash: span.textHash,
    createdAt,
  };
}

function payloadSpansForDoc(value: unknown, doc: string): Span[] {
  return deserializeProvenanceSpans(value).flatMap((span) => {
    const fieldSpan = payloadSpanToFieldSpan(span, doc);
    return fieldSpan ? [fieldSpan] : [];
  });
}

function fieldSpanToPayload(span: Span): ProvenanceSpanJSON {
  const createdAtSeconds = Math.floor(span.createdAt / 1000) * 1000;
  return {
    spanId: span.spanId,
    start: span.start,
    end: span.end,
    origin: span.origin,
    requestId: span.requestId,
    sourceId: span.sourceId,
    meta: JSON.stringify(span.meta),
    textHash: span.textHash,
    createdAt: new Date(createdAtSeconds).toISOString().replace('.000Z', 'Z'),
  };
}

function serializeFieldSpans(spans: Span[], doc: string): ProvenanceSpanJSON[] {
  return serializeProvenanceSpans(normalizeSpans(spans, doc).map(fieldSpanToPayload));
}

function persistNewUnanchoredMarginNotes(rawNotes: Stream['marginNotes'], notes: MarginNote[]): void {
  const rawStatusById = new Map(rawNotes.map((note) => [note.noteId, note.status]));
  for (const note of notes) {
    if (note.status === 'unanchored' && rawStatusById.get(note.noteId) === 'open') {
      updateMarginNote({ noteId: note.noteId, status: 'unanchored' });
    }
  }
}

function spanIdsIntersectingRange(spans: Span[], from: number, to: number): string[] {
  return spans
    .filter((span) => span.start < to && span.end > from)
    .map((span) => span.spanId);
}

function parseDocumentAIVerb(value: unknown): DocumentAIVerb {
  return value === 'ask' || value === 'challenge' || value === 'define' || value === 'develop'
    ? value
    : 'develop';
}

function promptFromUserInput(userInput: string): string {
  const marker = '\n\nPrompt:\n';
  const index = userInput.indexOf(marker);
  return index >= 0 ? userInput.slice(index + marker.length).trim() : '';
}

function replacementPreview(text: string): string {
  const compact = text.trim().replace(/\s+/g, ' ');
  return compact.length > 60 ? `${compact.slice(0, 60)}…` : compact;
}

type ArrivalRange = {
  id: string;
  from: number;
  to: number;
};

const addArrivalEffect = StateEffect.define<ArrivalRange>();
const clearArrivalEffect = StateEffect.define<string>();
const arrivedLineDecoration = Decoration.line({ class: 'cm-arrived' });

const arrivalField = StateField.define<readonly ArrivalRange[]>({
  create: () => [],
  update(value, transaction) {
    let next = value
      .map((range) => ({
        id: range.id,
        from: transaction.changes.mapPos(range.from, -1),
        to: transaction.changes.mapPos(range.to, 1),
      }))
      .filter((range) => range.from < range.to);

    for (const effect of transaction.effects) {
      if (effect.is(addArrivalEffect)) {
        next = [...next, effect.value];
      } else if (effect.is(clearArrivalEffect)) {
        next = next.filter((range) => range.id !== effect.value);
      }
    }

    return next;
  },
  provide: (field) => EditorView.decorations.compute([field], (state) => {
    const lineStarts = new Set<number>();
    for (const range of state.field(field)) {
      const end = Math.min(range.to, state.doc.length);
      let line = state.doc.lineAt(Math.min(range.from, state.doc.length));
      while (line.from < end) {
        lineStarts.add(line.from);
        if (line.to >= end || line.number >= state.doc.lines) break;
        line = state.doc.line(line.number + 1);
      }
    }

    const builder = new RangeSetBuilder<Decoration>();
    for (const lineFrom of [...lineStarts].sort((a, b) => a - b)) {
      builder.add(lineFrom, lineFrom, arrivedLineDecoration);
    }
    return builder.finish();
  }),
});

function durationTokenMs(element: Element, token: string, fallbackMs: number): number {
  const value = getComputedStyle(element).getPropertyValue(token).trim();
  if (value.endsWith('ms')) return Number.parseFloat(value);
  if (value.endsWith('s')) return Number.parseFloat(value) * 1000;
  return fallbackMs;
}

const markdownHighlightStyle = HighlightStyle.define([
  {
    tag: t.heading,
    class: 'cm-md-heading',
  },
  {
    tag: t.heading1,
    class: 'cm-md-heading-1',
  },
  {
    tag: t.heading2,
    class: 'cm-md-heading-2',
  },
  {
    tag: t.heading3,
    class: 'cm-md-heading-3',
  },
  {
    tag: [t.link, t.url],
    color: 'var(--color-accent)',
    textDecoration: 'none',
  },
  {
    tag: t.processingInstruction,
    color: 'var(--color-text-tertiary)',
  },
  {
    tag: t.emphasis,
    color: 'var(--text)',
    fontStyle: 'italic',
  },
  {
    tag: t.strong,
    color: 'var(--text)',
    fontWeight: '600',
  },
  {
    tag: t.monospace,
    class: 'cm-md-inline-code',
  },
  {
    tag: [t.quote, t.contentSeparator, t.list],
    color: 'var(--color-text-secondary)',
  },
  {
    tag: [t.labelName, t.string],
    color: 'var(--color-text-secondary)',
  },
]);

export function StreamEditor({
  stream,
  onBack,
  onDelete,
  pendingCellId,
  pendingSourceId,
  onClearPendingCell,
  onClearPendingSource,
}: StreamEditorProps) {
  const addToast = useToastStore((state) => state.addToast);

  const [title, setTitle] = useState(stream.title);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [isPrepaintHidden, setIsPrepaintHidden] = useState(true);
  const [showSourcesModal, setShowSourcesModal] = useState(false);
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);
  const [isProvenanceXrayVisible, setIsProvenanceXrayVisible] = useState(false);
  const [isMarginNotesVisible, setIsMarginNotesVisible] = useState(false);
  const [readBackScope, setReadBackScope] = useState<ReadBackScope>('viewport');
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [markdownContent, setMarkdownContent] = useState(stream.document?.markdown ?? '');
  const [showPrompt, setShowPrompt] = useState(false);
  const [promptValue, setPromptValue] = useState('');
  const [promptIntent, setPromptIntent] = useState<PromptIntent>({ kind: 'ask' });
  const [exchangeOverlay, setExchangeOverlay] = useState<ExchangeOverlayState | null>(null);
  const [sourceScope, setSourceScope] = useState<SourceScope>(stream.sourceScope ?? 'auto');
  const [aiStatus, setAiStatus] = useState<'idle' | 'thinking'>('idle');
  const [showRewriteMenu, setShowRewriteMenu] = useState(false);
  const [floatingMenu, setFloatingMenu] = useState<FloatingMenuState>({
    visible: false,
    left: 0,
    top: 0,
    selectionFrom: 0,
    selectionTo: 0,
    selectionHead: 0,
  });
  const [linkPopover, setLinkPopover] = useState<LinkPopoverState>({
    visible: false,
    left: 0,
    top: 0,
    from: 0,
    to: 0,
    labelFrom: 0,
    label: '',
    url: '',
  });
  const [aiFeedback, setAiFeedback] = useState<AiFeedbackState>({
    visible: false,
    kind: 'writing',
    message: 'AI is writing',
  });
  const [sourceIndexNotice, setSourceIndexNotice] = useState<string | null>(null);
  const [pdfPaneState, setPDFPaneState] = useState<PDFPaneState>({ visible: false });

  const titleInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const editorViewRef = useRef<EditorView | null>(null);
  const selectionActionMenuRef = useRef<HTMLDivElement>(null);
  const linkPopoverRef = useRef<HTMLDivElement>(null);
  const lastSavedContentRef = useRef(stream.document?.markdown ?? '');
  const markdownContentRef = useRef(stream.document?.markdown ?? '');
  const revisionRef = useRef(stream.document?.revision ?? 0);
  const promptContextRef = useRef<SelectionContext | null>(null);
  const selectionMenuTimerRef = useRef<number | null>(null);
  const aiFeedbackTimerRef = useRef<number | null>(null);
  const sourceIndexNoticeTimerRef = useRef<number | null>(null);
  const scrollSaveTimerRef = useRef<number | null>(null);
  const scrollCleanupRef = useRef<(() => void) | null>(null);
  const revealFrameRef = useRef<number | null>(null);
  const pendingPDFAnchorSelectionRef = useRef<PendingPDFAnchorSelection | null>(null);
  const sourcesRef = useRef<SourceReference[]>(stream.sources);
  const sourceIndexStatusesRef = useRef<Map<string, SourceReference['indexStatus']>>(new Map());
  const showPromptRef = useRef(showPrompt);
  const isAiThinkingRef = useRef(false);
  const aiRequestRef = useRef<{
    id: string;
    buffer: string;
    mode: 'replace' | 'after';
    verb: DocumentAIVerb;
    originalText: string;
    prefix: string;
    model?: string;
    parentRequestId?: string;
  } | null>(null);

  const insertImageAtCursor = useCallback((imageUrl: string, altText = 'image') => {
    const snippet = `\n${buildMarkdownImageToken({ alt: altText, url: imageUrl })}\n`;
    const view = editorViewRef.current;

    if (!view) {
      setMarkdownContent((prev) => `${prev}${snippet}`);
      return;
    }

    const selection = view.state.selection.main;
    view.dispatch({
      changes: {
        from: selection.from,
        to: selection.to,
        insert: snippet,
      },
      selection: { anchor: selection.from + snippet.length },
    });
    view.focus();
  }, []);

  const insertTextAtCursor = useCallback((snippet: string) => {
    const view = editorViewRef.current;

    if (!view) {
      setMarkdownContent((prev) => `${prev}${snippet}`);
      return;
    }

    const selection = view.state.selection.main;
    view.dispatch({
      changes: {
        from: selection.from,
        to: selection.to,
        insert: snippet,
      },
      selection: { anchor: selection.from + snippet.length },
      annotations: Transaction.addToHistory.of(true),
    });
    view.focus();
  }, []);

  const editorAPI = useMemo<EditorAPI>(() => ({
    insertImage: (imageUrl: string) => insertImageAtCursor(imageUrl),
  }), [insertImageAtCursor]);

  const { sources, setSources } = useBridgeMessages({
    streamId: stream.id,
    initialSources: stream.sources,
    editorAPI,
  });
  const isAiThinking = aiStatus === 'thinking';

  useEffect(() => {
    sourcesRef.current = sources;
    sourceIndexStatusesRef.current = new Map(
      sources.map((source) => [source.id, source.indexStatus])
    );
  }, [sources]);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type !== 'sourceIndexStatusChanged') return;

      const sourceId = message.payload?.sourceId as string | undefined;
      const status = message.payload?.status;
      if (!sourceId) return;
      if (
        status !== 'pending'
        && status !== 'indexing'
        && status !== 'ready'
        && status !== 'failed_no_text'
        && status !== 'failed'
      ) {
        return;
      }

      sourceIndexStatusesRef.current.set(sourceId, status);
    });

    return () => unsubscribe();
  }, []);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type !== 'getEditorSelection') return;

      const requestId = message.payload?.requestId as string | undefined;
      if (!requestId) return;

      const view = editorViewRef.current;
      const text = view
        ? view.state.selection.ranges
            .filter((range) => !range.empty)
            .map((range) => view.state.sliceDoc(range.from, range.to))
            .join('\n')
        : '';

      bridge.send({
        type: 'editorSelection',
        payload: { requestId, text },
      });
    });

    return () => unsubscribe();
  }, []);

  const isEditorActive = useCallback(() => {
    const shell = editorShellRef.current;
    const active = document.activeElement;
    if (!shell || !active) return false;
    return shell.contains(active);
  }, []);

  const clearAiFeedbackTimer = useCallback(() => {
    if (aiFeedbackTimerRef.current !== null) {
      window.clearTimeout(aiFeedbackTimerRef.current);
      aiFeedbackTimerRef.current = null;
    }
  }, []);

  const showAiWritingFeedback = useCallback(() => {
    clearAiFeedbackTimer();
    setAiFeedback({
      visible: true,
      kind: 'writing',
      message: 'AI is writing',
    });
  }, [clearAiFeedbackTimer]);

  const hideAiFeedback = useCallback(() => {
    clearAiFeedbackTimer();
    setAiFeedback((previous) => (previous.visible ? { ...previous, visible: false } : previous));
  }, [clearAiFeedbackTimer]);

  const showAiErrorFeedback = useCallback((message: string) => {
    clearAiFeedbackTimer();
    setAiFeedback({
      visible: true,
      kind: 'error',
      message,
    });
    aiFeedbackTimerRef.current = window.setTimeout(() => {
      aiFeedbackTimerRef.current = null;
      setAiFeedback((previous) => (previous.kind === 'error' ? { ...previous, visible: false } : previous));
    }, AI_ERROR_FEEDBACK_MS);
  }, [clearAiFeedbackTimer]);

  const clearSourceIndexNoticeTimer = useCallback(() => {
    if (sourceIndexNoticeTimerRef.current !== null) {
      window.clearTimeout(sourceIndexNoticeTimerRef.current);
      sourceIndexNoticeTimerRef.current = null;
    }
  }, []);

  const showSourceIndexNotice = useCallback((sourceName: string) => {
    clearSourceIndexNoticeTimer();
    setSourceIndexNotice(`Still indexing ${sourceName} — answers may not cover it yet.`);
    sourceIndexNoticeTimerRef.current = window.setTimeout(() => {
      sourceIndexNoticeTimerRef.current = null;
      setSourceIndexNotice(null);
    }, AI_INDEXING_NOTICE_MS);
  }, [clearSourceIndexNoticeTimer]);

  const clearScrollSaveTimer = useCallback(() => {
    if (scrollSaveTimerRef.current !== null) {
      window.clearTimeout(scrollSaveTimerRef.current);
      scrollSaveTimerRef.current = null;
    }
  }, []);

  const sendScrollPosition = useCallback((offset: number) => {
    bridge.send({
      type: 'saveScrollPosition',
      payload: { streamId: stream.id, offset: Math.max(0, offset) },
    });
  }, [stream.id]);

  const scheduleScrollPositionSave = useCallback(() => {
    clearScrollSaveTimer();
    scrollSaveTimerRef.current = window.setTimeout(() => {
      scrollSaveTimerRef.current = null;
      const view = editorViewRef.current;
      if (view) {
        sendScrollPosition(view.scrollDOM.scrollTop);
      }
    }, 1000);
  }, [clearScrollSaveTimer, sendScrollPosition]);

  const flushScrollPosition = useCallback(() => {
    clearScrollSaveTimer();
    const view = editorViewRef.current;
    if (view) {
      sendScrollPosition(view.scrollDOM.scrollTop);
    }
  }, [clearScrollSaveTimer, sendScrollPosition]);

  const clearRevealFrame = useCallback(() => {
    if (revealFrameRef.current !== null) {
      window.cancelAnimationFrame(revealFrameRef.current);
      revealFrameRef.current = null;
    }
  }, []);

  const cycleSourceScope = useCallback(() => {
    setSourceScope((previous) => {
      const next = nextSourceScope(previous);
      bridge.send({
        type: 'setSourceScope',
        payload: { streamId: stream.id, scope: next },
      });
      return next;
    });
  }, [stream.id]);

  const applyMarginNotesToEditor = useCallback((rawNotes: Stream['marginNotes']) => {
    const view = editorViewRef.current;
    if (!view) return;
    const notes = payloadMarginNotesForDoc(rawNotes, view.state.doc);
    view.dispatch({
      effects: setMarginNotes.of(notes),
      annotations: Transaction.addToHistory.of(false),
    });
    persistNewUnanchoredMarginNotes(rawNotes, notes);
  }, []);

  const persistMarginNoteStatus = useCallback((note: Pick<MarginNote, 'noteId'>, status: MarginNoteStatus) => {
    updateMarginNote({ noteId: note.noteId, status });
  }, []);

  const handleDismissMarginNote = useCallback((note: MarginNote) => {
    const view = editorViewRef.current;
    if (view) {
      view.dispatch({
        effects: updateMarginNoteStatusEffect.of({ noteId: note.noteId, status: 'dismissed' }),
        annotations: Transaction.addToHistory.of(false),
      });
      view.focus();
    }
    persistMarginNoteStatus(note, 'dismissed');
  }, [persistMarginNoteStatus]);

  const handlePromoteMarginNote = useCallback((note: MarginNote) => {
    const view = editorViewRef.current;
    if (!view) return;
    const currentNote = currentMarginNotes(view.state).find((candidate) => candidate.noteId === note.noteId) ?? note;
    const edit = buildPromoteMarginNoteEdit(currentNote, view.state.doc.toString());
    if (!edit) return;

    view.dispatch({
      changes: { from: edit.from, insert: edit.insert },
      selection: { anchor: edit.from + edit.insert.length },
      effects: [
        addSpans.of([edit.span]),
        updateMarginNoteStatusEffect.of({ noteId: note.noteId, status: 'promoted' }),
      ],
      annotations: [
        Transaction.addToHistory.of(true),
        Transaction.userEvent.of('input'),
        isolateHistory.of('full'),
      ],
    });
    view.focus();
    persistMarginNoteStatus(note, 'promoted');
  }, [persistMarginNoteStatus]);

  const handleReadBack = useCallback(() => {
    const view = editorViewRef.current;
    if (!view) return;
    const range = readBackRangeForScope(view, readBackScope);
    if (range.to <= range.from || !view.state.doc.sliceString(range.from, range.to).trim()) {
      addToast('Nothing in this scope to read back.', 'info');
      return;
    }
    readBack({
      streamId: stream.id,
      scopeStart: range.from,
      scopeEnd: range.to,
    });
  }, [addToast, readBackScope, stream.id]);

  useEffect(() => {
    setMarkdownContent(stream.document?.markdown ?? '');
    lastSavedContentRef.current = stream.document?.markdown ?? '';
    markdownContentRef.current = stream.document?.markdown ?? '';
    revisionRef.current = stream.document?.revision ?? 0;
    sourcesRef.current = stream.sources;
    sourceIndexStatusesRef.current = new Map(
      stream.sources.map((source) => [source.id, source.indexStatus])
    );
    setTitle(stream.title);
    setSaveState('saved');
    setAiStatus('idle');
    hideAiFeedback();
    clearSourceIndexNoticeTimer();
    setSourceIndexNotice(null);
    setFloatingMenu({
      visible: false,
      left: 0,
      top: 0,
      selectionFrom: 0,
      selectionTo: 0,
      selectionHead: 0,
    });
    setLinkPopover((previous) => (previous.visible ? { ...previous, visible: false } : previous));
    setShowPrompt(false);
    setPromptValue('');
    setPromptIntent({ kind: 'ask' });
    setExchangeOverlay(null);
    setSourceScope(stream.sourceScope ?? 'auto');
    setIsProvenanceXrayVisible(false);
    setIsMarginNotesVisible(false);
    setReadBackScope('viewport');
    setShowRewriteMenu(false);
    promptContextRef.current = null;
    aiRequestRef.current = null;
    const view = editorViewRef.current;
    if (view) {
      const notes = payloadMarginNotesForDoc(stream.marginNotes, stream.document?.markdown ?? '');
      view.dispatch({
        effects: [
          setSpans.of(payloadSpansForDoc(stream.spans, stream.document?.markdown ?? '')),
          setMarginNotes.of(notes),
        ],
        annotations: Transaction.addToHistory.of(false),
      });
      persistNewUnanchoredMarginNotes(stream.marginNotes, notes);
      dispatchAiRangeClear(view);
    }
  }, [clearSourceIndexNoticeTimer, hideAiFeedback, stream.id, stream.document?.markdown, stream.document?.revision, stream.sourceScope, stream.spans, stream.title]);

  useEffect(() => {
    applyMarginNotesToEditor(stream.marginNotes);
  }, [applyMarginNotesToEditor, stream.id, stream.marginNotes]);

  useEffect(() => {
    markdownContentRef.current = markdownContent;
  }, [markdownContent]);

  useEffect(() => {
    if (!pendingSourceId) return;
    if (sources.some((source) => source.id === pendingSourceId)) {
      setHighlightedSourceId(pendingSourceId);
      setShowSourcesModal(true);
      return;
    }

    if (sources.length === 0) {
      setHighlightedSourceId(null);
      onClearPendingSource?.();
    }
  }, [onClearPendingSource, pendingSourceId, sources]);

  useEffect(() => {
    if (pendingCellId) {
      addToast('Cell anchors are not available in document editor mode yet.', 'info');
      onClearPendingCell?.();
    }
  }, [pendingCellId, addToast, onClearPendingCell]);

  useEffect(() => {
    if (markdownContent === lastSavedContentRef.current) return;
    setSaveState('saving');

    const timer = window.setTimeout(() => {
      const contentToSave = markdownContent;
      const baseRevision = revisionRef.current;
      const view = editorViewRef.current;

      void bridge.sendAsync<{ revision: number }>('saveStreamDocument', {
        streamId: stream.id,
        markdown: contentToSave,
        baseRevision,
        spans: view ? serializeFieldSpans(currentSpans(view.state), contentToSave) : [],
      }).then((response) => {
        if (Number.isFinite(response.revision)) {
          revisionRef.current = response.revision;
        }
        lastSavedContentRef.current = contentToSave;
        if (markdownContentRef.current === contentToSave) {
          setSaveState('saved');
        }
      }).catch((error) => {
        debugWarn('[StreamEditor] Failed to save stream document', {
          streamId: stream.id,
          baseRevision,
          error: error instanceof Error ? error.message : String(error),
        });
      });
    }, 350);

    return () => window.clearTimeout(timer);
  }, [markdownContent, stream.id]);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'streamDocumentConflict') {
        const payloadStreamId = message.payload?.streamId as string | undefined;
        const markdown = message.payload?.markdown as string | undefined;
        const revision = Number(message.payload?.revision);

        if (!payloadStreamId || payloadStreamId !== stream.id || typeof markdown !== 'string' || !Number.isFinite(revision)) {
          return;
        }

        const view = editorViewRef.current;
        const spans = payloadSpansForDoc(message.payload?.spans, markdown);
        if (view) {
          view.dispatch({
            changes: { from: 0, to: view.state.doc.length, insert: markdown },
            effects: setSpans.of(spans),
          });
        }

        revisionRef.current = revision;
        markdownContentRef.current = markdown;
        lastSavedContentRef.current = markdown;
        setMarkdownContent(markdown);
        setSaveState('saved');

        debugWarn('[StreamEditor] Reloaded document after revision conflict', {
          streamId: stream.id,
          revision,
        });
        return;
      }

      if (message.type === 'streamDocumentAppended') {
        const payloadStreamId = message.payload?.streamId as string | undefined;
        const fragment = message.payload?.fragment as string | undefined;
        const revision = Number(message.payload?.revision);

        if (!payloadStreamId || payloadStreamId !== stream.id || typeof fragment !== 'string' || fragment.length === 0) {
          return;
        }

        const view = editorViewRef.current;
        const currentMarkdown = view?.state.doc.toString() ?? markdownContentRef.current;
        const hadUnsavedChanges = currentMarkdown !== lastSavedContentRef.current;

        const insertion = computeAppendInsertion(currentMarkdown.length, fragment);
        const insert = insertion.insert;
        const nextMarkdown = `${currentMarkdown}${insert}`;
        const spans = payloadSpansForDoc(message.payload?.spans, nextMarkdown);

        if (view) {
          const arrivalId = crypto.randomUUID();
          view.dispatch({
            changes: { from: insertion.from, insert },
            effects: [
              EditorView.scrollIntoView(insertion.insertedEnd, { y: 'nearest' }),
              addSpans.of(spans),
              addArrivalEffect.of({ id: arrivalId, from: insertion.from, to: insertion.insertedEnd }),
            ],
          });
          window.setTimeout(() => {
            if (editorViewRef.current === view) {
              view.dispatch({
                effects: clearArrivalEffect.of(arrivalId),
                annotations: Transaction.addToHistory.of(false),
              });
            }
          }, durationTokenMs(view.dom, '--duration-base', 200) * 3);
        }

        if (Number.isFinite(revision)) {
          revisionRef.current = revision;
        }
        markdownContentRef.current = nextMarkdown;
        if (!hadUnsavedChanges) {
          lastSavedContentRef.current = nextMarkdown;
          setSaveState('saved');
        }
        setMarkdownContent(nextMarkdown);
        return;
      }

      const active = aiRequestRef.current;
      if (!active) return;

      if (message.type === 'documentAIChunk') {
        const requestId = message.payload?.requestId as string | undefined;
        const chunk = message.payload?.chunk as string | undefined;
        if (!requestId || requestId !== active.id || !chunk) return;
        active.buffer += chunk;

        const view = editorViewRef.current;
        const range = view ? getAiWritingRange(view.state) : null;
        if (view && range) {
          view.dispatch({
            changes: { from: range.to, insert: chunk },
            effects: setAiWritingRangeEffect.of({ from: range.from, to: range.to + chunk.length }),
            annotations: Transaction.addToHistory.of(false),
          });
        }
        return;
      }

      if (message.type === 'documentModelSelected') {
        const requestId = message.payload?.requestId as string | undefined;
        if (!requestId || requestId !== active.id) return;
        const modelId = message.payload?.modelId as string | undefined;
        if (modelId) active.model = modelId;
        return;
      }

      if (message.type === 'documentAIError') {
        const requestId = message.payload?.requestId as string | undefined;
        const error = message.payload?.error as string | undefined;
        if (!requestId || requestId !== active.id) return;

        const errorCode = message.payload?.errorCode as string | undefined;
        const recovery = documentAIErrorRecovery(active.originalText, errorCode);
        const proxyRequestId = message.payload?.proxyRequestId as string | undefined;
        let displayError = error || 'AI request failed.';

        if (errorCode === 'quota_exceeded') {
          const scope = message.payload?.quotaScope as string | undefined;
          const resetAt = message.payload?.quotaResetAt as string | undefined;
          if (resetAt) {
            try {
              const resetDate = new Date(resetAt);
              const now = new Date();
              const hoursUntil = Math.ceil((resetDate.getTime() - now.getTime()) / (1000 * 60 * 60));
              displayError = `${scope === 'day' ? 'Daily' : 'Monthly'} quota exceeded. Resets in ~${hoursUntil}h.`;
            } catch {
              displayError = error || displayError;
            }
          }
        } else if (errorCode === 'rate_limited') {
          const retryAfter = message.payload?.retryAfter as number | undefined;
          if (retryAfter) {
            displayError = `Rate limit exceeded. Try again in ${retryAfter}s.`;
          }
        } else if (errorCode === 'invalid_key' || errorCode === 'key_bound_elsewhere') {
          displayError = `${displayError} Check Settings to update your device key.`;
        } else if (errorCode === 'server_error' || errorCode === 'upstream_error') {
          if (proxyRequestId) {
            displayError = `${displayError} (Request ID: ${proxyRequestId})`;
          }
        }

        const view = editorViewRef.current;
        const range = view ? getAiWritingRange(view.state) : null;
        if (view && range) {
          view.dispatch({
            changes: { from: range.from, to: range.to, insert: recovery.restoreText },
            selection: { anchor: range.from + recovery.restoreText.length },
            effects: setAiWritingRangeEffect.of(null),
            annotations: Transaction.addToHistory.of(false),
          });
          view.focus();
        } else if (view) {
          dispatchAiRangeClear(view);
        }

        setAiStatus('idle');
        aiRequestRef.current = null;
        if (recovery.silent) {
          hideAiFeedback();
        } else {
          showAiErrorFeedback(displayError);
          addToast(displayError, 'error');
        }
        return;
      }

      if (message.type === 'documentAIComplete') {
        const requestId = message.payload?.requestId as string | undefined;
        if (!requestId || requestId !== active.id) return;

        const view = editorViewRef.current;
        if (!view) {
          setAiStatus('idle');
          aiRequestRef.current = null;
          hideAiFeedback();
          return;
        }

        const rawOutput = active.buffer.trim();
        if (!rawOutput) {
          const range = getAiWritingRange(view.state);
          if (range) {
            view.dispatch({
              changes: { from: range.from, to: range.to, insert: active.originalText },
              selection: { anchor: range.from + active.originalText.length },
              effects: setAiWritingRangeEffect.of(null),
              annotations: Transaction.addToHistory.of(false),
            });
          } else {
            dispatchAiRangeClear(view);
          }
          view.focus();
          setAiStatus('idle');
          aiRequestRef.current = null;
          showAiErrorFeedback('AI returned empty output.');
          addToast('AI returned empty output.', 'warning');
          return;
        }

        const range = getAiWritingRange(view.state);
        if (!range) {
          setAiStatus('idle');
          aiRequestRef.current = null;
          hideAiFeedback();
          return;
        }

        const citations = parseDocumentAICitations(message.payload?.citations);
        const sourceContextMode = parseDocumentAISourceContextMode(message.payload?.sourceContextMode);
        let finalOutput = rawOutput;
        let provenanceLine: string | null = null;

        if (citations) {
          const result = swapCitationMarkersWithMetadata(rawOutput, citations);
          finalOutput = result.text;
          provenanceLine = buildProvenanceLine(result.swappedCitations);
        } else if (sourceContextMode === 'none') {
          provenanceLine = '*From model knowledge.*';
        }

        if (provenanceLine) {
          finalOutput = `${finalOutput}\n\n${provenanceLine}`;
        }

        if (active.verb === 'challenge') {
          finalOutput = wrapChallengeOutput(finalOutput);
        }

        const suffix = active.mode === 'after' && !finalOutput.endsWith('\n') ? '\n' : '';
        const insertText = `${active.prefix}${finalOutput}${suffix}`;
        const finalFrom = range.from;
        const originalTo = finalFrom + active.originalText.length;
        const span = buildDocumentAIProvenanceSpan({
          requestId,
          start: finalFrom,
          text: insertText,
          verb: active.verb,
          model: active.model,
          parentRequestId: active.parentRequestId,
        });

        view.dispatch({
          changes: { from: range.from, to: range.to, insert: active.originalText },
          annotations: Transaction.addToHistory.of(false),
        });

        view.dispatch({
          changes: { from: finalFrom, to: originalTo, insert: insertText },
          selection: { anchor: finalFrom + insertText.length },
          effects: [
            setAiWritingRangeEffect.of(null),
            addSpans.of([span]),
          ],
          annotations: [
            Transaction.addToHistory.of(true),
            Transaction.userEvent.of(AI_HISTORY_USER_EVENT),
            isolateHistory.of('full'),
          ],
        });
        view.focus();

        setAiStatus('idle');
        aiRequestRef.current = null;
        hideAiFeedback();
        return;
      }
    });

    return () => unsubscribe();
  }, [addToast, hideAiFeedback, showAiErrorFeedback, stream.id]);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type !== 'pdfHighlightLinked') return;

      const payloadStreamId = message.payload?.streamId as string | undefined;
      if (!payloadStreamId || payloadStreamId !== stream.id) return;

      const sourceId = message.payload?.sourceId as string | undefined;
      const sourcePayload = message.payload as SourceTitlePayload | undefined;
      const sourceName = sourcePayload?.sourceName;
      const shortTitle = sourcePayload?.shortTitle;
      const highlightId = message.payload?.highlightId as string | undefined;
      const page = message.payload?.page as number | undefined;
      const quote = message.payload?.quote as string | undefined;

      if (!sourceId || !highlightId) return;

      const pageNumber = Number.isFinite(page) ? Math.max(1, Math.round(page as number)) : 1;
      const linkUrl = `ticker-pdf://${sourceId}?highlight=${encodeURIComponent(highlightId)}&page=${pageNumber}`;
      const compactQuote = (quote || '').trim().replace(/\s+/g, ' ');
      const quoteLine = compactQuote ? `> ${compactQuote}\n` : '';
      const linkLabel = `${shortTitle || sourceName || 'PDF'} p.${pageNumber}`;
      const snippet = `\n${quoteLine}[${linkLabel}](${linkUrl})\n`;

      insertTextAtCursor(snippet);
      addToast('Linked PDF selection inserted into stream.', 'success');
    });

    return () => unsubscribe();
  }, [addToast, insertTextAtCursor, stream.id]);

  useEffect(() => {
    pendingPDFAnchorSelectionRef.current = null;
    setPDFPaneState((previous) => (
      previous.streamId && previous.streamId !== stream.id ? { visible: false } : previous
    ));
  }, [stream.id]);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'pdfPaneStateChanged') {
        const visible = message.payload?.visible === true;
        const nextState: PDFPaneState = {
          visible,
          streamId: message.payload?.streamId as string | undefined,
          sourceId: message.payload?.sourceId as string | undefined,
          sourceName: (message.payload as SourceTitlePayload | undefined)?.sourceName,
          shortTitle: (message.payload as SourceTitlePayload | undefined)?.shortTitle,
        };
        setPDFPaneState(nextState);
        if (!visible || nextState.streamId !== stream.id) {
          pendingPDFAnchorSelectionRef.current = null;
        }
        return;
      }

      if (message.type === 'pdfAnchorPickCancelled') {
        const payloadStreamId = message.payload?.streamId as string | undefined;
        if (payloadStreamId === stream.id) {
          pendingPDFAnchorSelectionRef.current = null;
        }
        return;
      }

      if (message.type !== 'pdfAnchorPlaced') return;

      const payloadStreamId = message.payload?.streamId as string | undefined;
      if (payloadStreamId !== stream.id) return;

      const pendingSelection = pendingPDFAnchorSelectionRef.current;
      pendingPDFAnchorSelectionRef.current = null;

      const sourceId = message.payload?.sourceId as string | undefined;
      const highlightId = message.payload?.highlightId as string | undefined;
      const page = message.payload?.page as number | undefined;
      if (!sourceId || !highlightId) return;

      const view = editorViewRef.current;
      if (!view || !pendingSelection) {
        addToast('The original selection is no longer available.', 'warning');
        return;
      }

      const pageNumber = Number.isFinite(page) ? Math.max(1, Math.round(page as number)) : 1;
      const linkURL = buildTickerPDFLinkURL({ sourceId, highlightId, page: pageNumber });
      const edit = buildPDFAnchorLinkEdit(view.state.doc.toString(), pendingSelection, linkURL);
      if (!edit) {
        addToast('The original selection is no longer available.', 'warning');
        return;
      }

      view.dispatch({
        changes: { from: edit.from, to: edit.to, insert: edit.insert },
        selection: { anchor: edit.from + edit.insert.length },
        annotations: [
          Transaction.userEvent.of('input'),
          isolateHistory.of('full'),
        ],
      });
      view.focus();
      addToast('Linked selection to PDF.', 'success');
    });

    return () => unsubscribe();
  }, [addToast, stream.id]);

  const startEditingTitle = useCallback(() => {
    setIsEditingTitle(true);
    setTimeout(() => titleInputRef.current?.select(), 0);
  }, []);

  const saveTitle = useCallback(() => {
    const trimmedTitle = title.trim() || 'Untitled';
    setTitle(trimmedTitle);
    setIsEditingTitle(false);
    if (trimmedTitle === stream.title) return;

    bridge.send({
      type: 'updateStreamTitle',
      payload: { id: stream.id, title: trimmedTitle },
    });
  }, [title, stream.id, stream.title]);

  const handleTitleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      saveTitle();
    } else if (e.key === 'Escape') {
      setTitle(stream.title);
      setIsEditingTitle(false);
    }
  }, [saveTitle, stream.title]);

  const readBlobAsBase64 = useCallback((blob: Blob): Promise<string> => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const dataUrl = reader.result as string;
        const parts = dataUrl.split(',');
        if (parts.length < 2) {
          reject(new Error('Invalid image encoding.'));
          return;
        }
        resolve(parts[1]);
      };
      reader.onerror = () => reject(new Error('Failed to read image data.'));
      reader.readAsDataURL(blob);
    });
  }, []);

  const saveImageToAssets = useCallback(async (blob: Blob): Promise<string> => {
    const requestId = crypto.randomUUID();
    const base64Data = await readBlobAsBase64(blob);

    return new Promise((resolve, reject) => {
      let settled = false;
      const timeout = window.setTimeout(() => {
        if (settled) return;
        settled = true;
        unsubscribe();
        reject(new Error('Timed out while saving image.'));
      }, 15000);

      const unsubscribe = bridge.onMessage((message) => {
        const payloadRequestId = message.payload?.requestId as string | undefined;
        if (payloadRequestId !== requestId) return;

        if (message.type === 'imageSaved' && message.payload?.assetUrl) {
          if (settled) return;
          settled = true;
          window.clearTimeout(timeout);
          unsubscribe();
          resolve(message.payload.assetUrl as string);
        }

        if (message.type === 'imageSaveError') {
          if (settled) return;
          settled = true;
          window.clearTimeout(timeout);
          unsubscribe();
          const messageText = (message.payload?.error as string | undefined) || 'Failed to save image.';
          reject(new Error(messageText));
        }
      });

      bridge.send({
        type: 'saveImage',
        payload: {
          streamId: stream.id,
          data: base64Data,
          requestId,
        },
      });
    });
  }, [readBlobAsBase64, stream.id]);

  const insertImageFiles = useCallback(async (files: File[]) => {
    for (const file of files) {
      if (!file.type.startsWith('image/')) continue;

      try {
        const assetUrl = await saveImageToAssets(file);
        insertImageAtCursor(assetUrl, file.name.replace(/\.[^.]+$/, ''));
      } catch (error) {
        const text = error instanceof Error ? error.message : 'Failed to insert image.';
        addToast(text, 'error');
      }
    }
  }, [saveImageToAssets, insertImageAtCursor, addToast]);

  const getSelectionContext = useCallback((allowFallback: boolean): SelectionContext | null => {
    const view = editorViewRef.current;
    if (!view) return null;
    const selection = view.state.selection.main;
    const doc = view.state.doc;

    if (selection.from !== selection.to) {
      const text = view.state.sliceDoc(selection.from, selection.to);
      return {
        text,
        from: selection.from,
        to: selection.to,
        imageUrls: extractMarkdownImageUrls(text),
      };
    }

    if (!allowFallback) return null;

    const cursorLine = doc.lineAt(selection.from);
    let startLine = cursorLine.number;
    let endLine = cursorLine.number;

    while (startLine > 1) {
      const prevLine = doc.line(startLine - 1);
      if (prevLine.text.trim().length === 0) break;
      startLine -= 1;
    }

    while (endLine < doc.lines) {
      const nextLine = doc.line(endLine + 1);
      if (nextLine.text.trim().length === 0) break;
      endLine += 1;
    }

    const from = doc.line(startLine).from;
    const to = doc.line(endLine).to;
    let text = view.state.sliceDoc(from, to).trim();

    if (!text) {
      text = view.state.sliceDoc(0, doc.length).trim();
      if (!text) return null;
      return {
        text,
        from: 0,
        to: doc.length,
        imageUrls: extractMarkdownImageUrls(text),
      };
    }

    return {
      text,
      from,
      to,
      imageUrls: extractMarkdownImageUrls(text),
    };
  }, []);

  const clearSelectionMenuTimer = useCallback(() => {
    if (selectionMenuTimerRef.current !== null) {
      window.clearTimeout(selectionMenuTimerRef.current);
      selectionMenuTimerRef.current = null;
    }
  }, []);

  const hideSelectionMenu = useCallback(() => {
    clearSelectionMenuTimer();
    setShowRewriteMenu(false);
    setFloatingMenu((previous) => (previous.visible ? { ...previous, visible: false } : previous));
  }, [clearSelectionMenuTimer]);

  const hideLinkPopover = useCallback(() => {
    setLinkPopover((previous) => (previous.visible ? { ...previous, visible: false } : previous));
  }, []);

  const getSelectionMenuPlacement = useCallback((
    view: EditorView,
    measuredMenuSize?: { width: number; height: number }
  ): { left: number; top: number } | null => {
    const shell = editorShellRef.current;
    if (!shell) return null;

    const selection = view.state.selection.main;
    const coords = view.coordsAtPos(selection.head) ?? view.coordsAtPos(selection.anchor);
    if (!coords) return null;

    const shellRect = shell.getBoundingClientRect();
    const menu = selectionActionMenuRef.current;
    return computeSelectionMenuPlacement({
      coords,
      shellRect,
      menuSize: measuredMenuSize ?? {
        width: menu?.offsetWidth,
        height: menu?.offsetHeight,
      },
      viewportHeight: window.innerHeight,
    });
  }, []);

  const getLinkPopoverPlacement = useCallback((
    view: EditorView,
    link: Pick<LinkPopoverState, 'from' | 'labelFrom'>,
    measuredMenuSize?: { width: number; height: number }
  ): { left: number; top: number } | null => {
    const shell = editorShellRef.current;
    if (!shell) return null;

    const anchor = Math.min(Math.max(link.labelFrom, link.from), view.state.doc.length);
    const coords = view.coordsAtPos(anchor) ?? view.coordsAtPos(link.from);
    if (!coords) return null;

    const shellRect = shell.getBoundingClientRect();
    const menu = linkPopoverRef.current;
    return computeSelectionMenuPlacement({
      coords,
      shellRect,
      menuSize: measuredMenuSize ?? {
        width: menu?.offsetWidth,
        height: menu?.offsetHeight,
      },
      viewportHeight: window.innerHeight,
    });
  }, []);

  useLayoutEffect(() => {
    if (!floatingMenu.visible) return;

    const menu = selectionActionMenuRef.current;
    const view = editorViewRef.current;
    if (!menu || !view) return;

    const measuredMenuSize = {
      width: menu.offsetWidth,
      height: menu.offsetHeight,
    };
    if (measuredMenuSize.width <= 0 || measuredMenuSize.height <= 0) return;

    const placement = getSelectionMenuPlacement(view, measuredMenuSize);
    if (!placement) return;

    setFloatingMenu((previous) => {
      if (!previous.visible) return previous;

      const sameSize = previous.menuWidth === measuredMenuSize.width &&
        previous.menuHeight === measuredMenuSize.height;
      const samePlacement = Math.abs(previous.left - placement.left) < 0.5 &&
        Math.abs(previous.top - placement.top) < 0.5;

      if (sameSize && samePlacement) {
        return previous;
      }

      return {
        ...previous,
        left: placement.left,
        top: placement.top,
        menuWidth: measuredMenuSize.width,
        menuHeight: measuredMenuSize.height,
      };
    });
  }, [
    floatingMenu.left,
    floatingMenu.menuHeight,
    floatingMenu.menuWidth,
    floatingMenu.selectionFrom,
    floatingMenu.selectionHead,
    floatingMenu.selectionTo,
    floatingMenu.top,
    floatingMenu.visible,
    getSelectionMenuPlacement,
    pdfPaneState.streamId,
    pdfPaneState.visible,
    stream.id,
  ]);

  useLayoutEffect(() => {
    if (!linkPopover.visible) return;

    const menu = linkPopoverRef.current;
    const view = editorViewRef.current;
    if (!menu || !view) return;

    const measuredMenuSize = {
      width: menu.offsetWidth,
      height: menu.offsetHeight,
    };
    if (measuredMenuSize.width <= 0 || measuredMenuSize.height <= 0) return;

    const placement = getLinkPopoverPlacement(view, linkPopover, measuredMenuSize);
    if (!placement) return;

    setLinkPopover((previous) => {
      if (!previous.visible) return previous;

      const sameSize = previous.menuWidth === measuredMenuSize.width &&
        previous.menuHeight === measuredMenuSize.height;
      const samePlacement = Math.abs(previous.left - placement.left) < 0.5 &&
        Math.abs(previous.top - placement.top) < 0.5;

      if (sameSize && samePlacement) {
        return previous;
      }

      return {
        ...previous,
        left: placement.left,
        top: placement.top,
        menuWidth: measuredMenuSize.width,
        menuHeight: measuredMenuSize.height,
      };
    });
  }, [
    getLinkPopoverPlacement,
    linkPopover,
    pdfPaneState.streamId,
    pdfPaneState.visible,
    stream.id,
  ]);

  const scheduleSelectionMenu = useCallback((view: EditorView) => {
    clearSelectionMenuTimer();

    if (showPromptRef.current || isAiThinkingRef.current) {
      hideSelectionMenu();
      return;
    }

    const selection = view.state.selection.main;
    if (selection.empty || !view.state.sliceDoc(selection.from, selection.to).trim()) {
      hideSelectionMenu();
      return;
    }

    selectionMenuTimerRef.current = window.setTimeout(() => {
      selectionMenuTimerRef.current = null;

      const currentView = editorViewRef.current;
      if (!currentView || currentView !== view || showPromptRef.current || isAiThinkingRef.current) {
        hideSelectionMenu();
        return;
      }

      const currentSelection = currentView.state.selection.main;
      const selectedText = currentView.state.sliceDoc(currentSelection.from, currentSelection.to);
      const placement = getSelectionMenuPlacement(currentView);
      if (currentSelection.empty || !selectedText.trim() || !placement) {
        hideSelectionMenu();
        return;
      }

      setFloatingMenu({
        visible: true,
        left: placement.left,
        top: placement.top,
        selectionFrom: currentSelection.from,
        selectionTo: currentSelection.to,
        selectionHead: currentSelection.head,
      });
    }, SELECTION_MENU_DELAY_MS);
  }, [clearSelectionMenuTimer, getSelectionMenuPlacement, hideSelectionMenu]);

  const openLinkPopover = useCallback((view: EditorView, link: MarkdownLinkInfo | null) => {
    if (!link) {
      hideLinkPopover();
      return;
    }

    const placement = getLinkPopoverPlacement(view, link);
    if (!placement) {
      hideLinkPopover();
      return;
    }

    hideSelectionMenu();
    setLinkPopover({
      visible: true,
      left: placement.left,
      top: placement.top,
      from: link.from,
      to: link.to,
      labelFrom: link.labelFrom,
      label: link.label,
      url: link.url,
    });
  }, [getLinkPopoverPlacement, hideLinkPopover, hideSelectionMenu]);

  const linkInteraction = useMemo<Extension>(
    () => linkInteractionExtension(openLinkPopover),
    [openLinkPopover]
  );

  const commitLinkPopover = useCallback(() => {
    if (!linkPopover.visible) return;

    const view = editorViewRef.current;
    const change = buildLinkEditChange(linkPopover, linkPopover.label, linkPopover.url);
    if (view && change) {
      view.dispatch({
        changes: change,
        selection: { anchor: change.from + change.insert.length },
        annotations: Transaction.addToHistory.of(true),
      });
      view.focus();
    }

    hideLinkPopover();
  }, [hideLinkPopover, linkPopover]);

  const unlinkLinkPopover = useCallback(() => {
    if (!linkPopover.visible) return;

    const view = editorViewRef.current;
    if (view) {
      view.dispatch({
        changes: { from: linkPopover.from, to: linkPopover.to, insert: linkPopover.label },
        selection: { anchor: linkPopover.from + linkPopover.label.length },
        annotations: Transaction.addToHistory.of(true),
      });
      view.focus();
    }

    hideLinkPopover();
  }, [hideLinkPopover, linkPopover]);

  const removeLinkPopover = useCallback(() => {
    if (!linkPopover.visible) return;

    const view = editorViewRef.current;
    if (view) {
      view.dispatch({
        changes: { from: linkPopover.from, to: linkPopover.to, insert: '' },
        selection: { anchor: linkPopover.from },
        annotations: Transaction.addToHistory.of(true),
      });
      view.focus();
    }

    hideLinkPopover();
  }, [hideLinkPopover, linkPopover]);

  const handleLinkPopoverBlur = useCallback((event: FocusEvent<HTMLDivElement>) => {
    const nextTarget = event.relatedTarget;
    if (nextTarget instanceof Node && event.currentTarget.contains(nextTarget)) return;

    window.setTimeout(() => {
      const menu = linkPopoverRef.current;
      if (menu && document.activeElement instanceof Node && menu.contains(document.activeElement)) return;
      commitLinkPopover();
    }, 0);
  }, [commitLinkPopover]);

  const handleLinkPopoverKeyDown = useCallback((event: ReactKeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      commitLinkPopover();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      hideLinkPopover();
      editorViewRef.current?.focus();
    }
  }, [commitLinkPopover, hideLinkPopover]);

  useEffect(() => {
    showPromptRef.current = showPrompt;
    isAiThinkingRef.current = isAiThinking;

    if (showPrompt || isAiThinking) {
      hideSelectionMenu();
      hideLinkPopover();
    }
  }, [hideLinkPopover, hideSelectionMenu, isAiThinking, showPrompt]);

  const selectionMenuExtension = useMemo<Extension>(() => [
    EditorView.updateListener.of((update) => {
      if (update.docChanged && pendingPDFAnchorSelectionRef.current) {
        pendingPDFAnchorSelectionRef.current = mapPendingPDFAnchorSelection(
          pendingPDFAnchorSelectionRef.current,
          update.changes
        );
      }

      const selection = update.state.selection.main;

      if (selection.empty) {
        if (update.selectionSet || update.docChanged) {
          hideSelectionMenu();
        }
        return;
      }

      if (update.selectionSet || update.geometryChanged) {
        scheduleSelectionMenu(update.view);
      }
    }),
    EditorView.domEventHandlers({
      blur: () => {
        hideSelectionMenu();
      },
    }),
  ], [hideSelectionMenu, scheduleSelectionMenu]);

  const startDocumentAI = useCallback((options: {
    query: string;
    context?: string;
    imageUrls?: string[];
    from: number;
    to: number;
    mode: 'replace' | 'after';
    verb?: DocumentAIVerb;
    parentRequestId?: string;
  }) => {
    if (isAiThinking) {
      addToast('AI is already running for this stream.', 'info');
      return;
    }

    const view = editorViewRef.current;
    if (!view) {
      addToast('Editor is not ready yet.', 'warning');
      return;
    }

    const docLength = view.state.doc.length;
    const from = Math.max(0, Math.min(options.from, docLength));
    const to = Math.max(from, Math.min(options.to, docLength));
    const originalText = options.mode === 'replace' ? view.state.doc.sliceString(from, to) : '';
    let rangeFrom = from;
    let rangeTo = from;
    let prefix = '';

    if (options.mode === 'after') {
      rangeFrom = to;
      rangeTo = to;
      const before = view.state.doc.sliceString(Math.max(0, to - 2), to);
      const needsBlankLine = !before.endsWith('\n\n');
      const needsSingleBreak = before.endsWith('\n') && !before.endsWith('\n\n');
      prefix = needsBlankLine ? '\n\n' : needsSingleBreak ? '\n' : '';
      rangeTo += prefix.length;
    }

    const initialChange = options.mode === 'replace'
      ? { from, to, insert: '' }
      : prefix
        ? { from: to, insert: prefix }
        : null;

    view.dispatch({
      changes: initialChange ?? undefined,
      selection: { anchor: rangeTo },
      effects: [
        setAiWritingRangeEffect.of({ from: rangeFrom, to: rangeTo }),
        EditorView.scrollIntoView(rangeTo, { y: 'nearest' }),
      ],
      annotations: [
        Transaction.addToHistory.of(false),
        isolateHistory.of('before'),
      ],
    });
    view.focus();

    const requestId = crypto.randomUUID();
    aiRequestRef.current = {
      id: requestId,
      buffer: '',
      mode: options.mode,
      verb: options.verb ?? 'develop',
      originalText,
      prefix,
      parentRequestId: options.parentRequestId,
    };
    setAiStatus('thinking');
    showAiWritingFeedback();

    const indexingSource = sourcesRef.current.find((source) => {
      const status = sourceIndexStatusesRef.current.get(source.id) ?? source.indexStatus;
      return status === 'indexing' || status === 'pending';
    });
    if (indexingSource) {
      showSourceIndexNotice(indexingSource.shortTitle || indexingSource.displayName);
    }

    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: options.query,
        context: options.context,
        sourceScope,
        verb: options.verb ?? 'develop',
        imageURLs: options.imageUrls ?? [],
        ...(options.parentRequestId ? { parentRequestId: options.parentRequestId } : {}),
      },
    });
  }, [addToast, isAiThinking, showAiWritingFeedback, showSourceIndexNotice, sourceScope, stream.id]);

  const handleSend = useCallback(() => {
    const context = getSelectionContext(true);
    if (!context || !context.text.trim()) {
      addToast('Select text or place the cursor in a paragraph to send.', 'info');
      return;
    }

    startDocumentAI({
      query: context.text.trim(),
      imageUrls: context.imageUrls,
      from: context.from,
      to: context.to,
      mode: 'replace',
      verb: 'develop',
    });
    hideSelectionMenu();
  }, [addToast, getSelectionContext, hideSelectionMenu, startDocumentAI]);

  const openPromptWithContext = useCallback((context: SelectionContext) => {
    hideSelectionMenu();
    promptContextRef.current = context;
    setPromptValue('');
    setPromptIntent({ kind: 'ask' });
    setShowPrompt(true);
  }, [hideSelectionMenu]);

  const handleOpenPrompt = useCallback(() => {
    if (isAiThinking) {
      addToast('AI is already running for this stream.', 'info');
      return;
    }
    const context = getSelectionContext(true);
    if (!context || !context.text.trim()) {
      addToast('Select text or place the cursor in a paragraph to use as context.', 'info');
      return;
    }
    openPromptWithContext(context);
  }, [addToast, getSelectionContext, isAiThinking, openPromptWithContext]);

  const handleSelectionFormat = useCallback((marker: string) => {
    const view = editorViewRef.current;
    if (!view) {
      hideSelectionMenu();
      return;
    }

    const edit = toggleInlineMark(view.state, view.state.selection.main, marker);
    if (!edit) {
      hideSelectionMenu();
      return;
    }

    view.dispatch({
      changes: edit.changes,
      selection: edit.newSelection,
      annotations: Transaction.userEvent.of('input.format'),
    });
    view.focus();
  }, [hideSelectionMenu]);

  const canLinkSelectionToPDF = pdfPaneState.visible && pdfPaneState.streamId === stream.id;

  const handleSelectionLinkToPDF = useCallback(() => {
    const context = getSelectionContext(false);
    if (!context || !context.text.trim()) {
      hideSelectionMenu();
      return;
    }
    if (!canLinkSelectionToPDF) {
      pendingPDFAnchorSelectionRef.current = null;
      hideSelectionMenu();
      addToast('Open a PDF source before linking to PDF.', 'info');
      return;
    }

    pendingPDFAnchorSelectionRef.current = { from: context.from, to: context.to };
    hideSelectionMenu();
    beginPDFAnchorPick(stream.id);
  }, [addToast, canLinkSelectionToPDF, getSelectionContext, hideSelectionMenu, stream.id]);

  const handleSelectionDissolve = useCallback(() => {
    const view = editorViewRef.current;
    if (!view) {
      hideSelectionMenu();
      return;
    }

    const selection = view.state.selection.main;
    const spanIds = spanIdsIntersectingRange(currentSpans(view.state), selection.from, selection.to);
    if (spanIds.length > 0) {
      view.dispatch({
        effects: dissolveSpans.of(spanIds),
        annotations: Transaction.addToHistory.of(true),
      });
      view.focus();
    }
    hideSelectionMenu();
  }, [hideSelectionMenu]);

  const handleSelectionVerb = useCallback((verb: DocumentAIVerb) => {
    const context = getSelectionContext(false);
    if (!context || !context.text.trim()) {
      hideSelectionMenu();
      return;
    }

    startDocumentAI({
      query: context.text.trim(),
      imageUrls: context.imageUrls,
      from: context.from,
      to: context.to,
      mode: verb === 'develop' ? 'replace' : 'after',
      verb,
    });
    hideSelectionMenu();
  }, [getSelectionContext, hideSelectionMenu, startDocumentAI]);

  const closePrompt = useCallback(() => {
    setShowPrompt(false);
    setPromptValue('');
    setPromptIntent({ kind: 'ask' });
    promptContextRef.current = null;
    hideSelectionMenu();
  }, [hideSelectionMenu]);

  const handlePromptSend = useCallback(() => {
    const prompt = promptValue.trim();
    const context = promptContextRef.current;
    if ((!prompt && promptIntent.kind === 'ask') || !context) return;

    closePrompt();

    if (promptIntent.kind === 'redevelop') {
      startDocumentAI({
        query: prompt || context.text.trim(),
        context: prompt ? context.text.trim() : undefined,
        imageUrls: context.imageUrls,
        from: context.from,
        to: context.to,
        mode: 'replace',
        verb: promptIntent.verb,
        parentRequestId: promptIntent.parentRequestId,
      });
      return;
    }

    startDocumentAI({
      query: prompt,
      context: context.text.trim(),
      imageUrls: context.imageUrls,
      from: context.from,
      to: context.to,
      mode: 'after',
      verb: 'ask',
    });
  }, [closePrompt, promptIntent, promptValue, startDocumentAI]);

  const handleStopDocumentAI = useCallback(() => {
    const active = aiRequestRef.current;
    if (!active) return;
    bridge.send({
      type: 'cancelDocumentAI',
      payload: { requestId: active.id },
    });
  }, []);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        if (!isEditorActive()) return;
        e.preventDefault();
        if (e.shiftKey) {
          handleOpenPrompt();
        } else {
          handleSend();
        }
        return;
      }
      if (e.key === 'Escape') {
        closePrompt();
        hideSelectionMenu();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [closePrompt, handleOpenPrompt, handleSend, hideSelectionMenu, isEditorActive]);

  useEffect(() => {
    return () => clearSelectionMenuTimer();
  }, [clearSelectionMenuTimer]);

  useEffect(() => {
    return () => clearAiFeedbackTimer();
  }, [clearAiFeedbackTimer]);

  useEffect(() => {
    return () => clearSourceIndexNoticeTimer();
  }, [clearSourceIndexNoticeTimer]);

  useEffect(() => {
    return () => {
      flushScrollPosition();
      scrollCleanupRef.current?.();
      scrollCleanupRef.current = null;
      clearRevealFrame();
    };
  }, [clearRevealFrame, flushScrollPosition]);

  useEffect(() => {
    const handlePaste = (event: ClipboardEvent) => {
      if (!isEditorActive()) return;
      if (!event.clipboardData?.items?.length) return;

      const imageFiles: File[] = [];
      for (const item of Array.from(event.clipboardData.items)) {
        if (!item.type.startsWith('image/')) continue;
        const file = item.getAsFile();
        if (file) imageFiles.push(file);
      }

      if (imageFiles.length === 0) return;

      event.preventDefault();
      void insertImageFiles(imageFiles);
    };

    window.addEventListener('paste', handlePaste);
    return () => window.removeEventListener('paste', handlePaste);
  }, [insertImageFiles, isEditorActive]);

  const handleDrop = useCallback((event: React.DragEvent<HTMLDivElement>) => {
    const files = Array.from(event.dataTransfer.files || []).filter((file) => file.type.startsWith('image/'));
    if (files.length === 0) return;
    event.preventDefault();
    event.stopPropagation();
    void insertImageFiles(files);
  }, [insertImageFiles]);

  const handleDragOver = useCallback((event: React.DragEvent<HTMLDivElement>) => {
    if (Array.from(event.dataTransfer.items || []).some((item) => item.type.startsWith('image/'))) {
      event.preventDefault();
    }
  }, []);

  const handleSourceRemoved = useCallback((sourceId: string) => {
    setSources((prev: SourceReference[]) => prev.filter((source) => source.id !== sourceId));
  }, [setSources]);

  const handleSourceAIExclusionChanged = useCallback((sourceId: string, aiExcluded: boolean) => {
    setSources((prev: SourceReference[]) => prev.map((source) => (
      source.id === sourceId ? { ...source, aiExcluded } : source
    )));
  }, [setSources]);

  const handleOpenSource = useCallback((source: SourceReference) => {
    bridge.send({
      type: 'openSource',
      payload: { sourceId: source.id },
    });
  }, []);

  const handleOpenSourceById = useCallback((sourceId: string) => {
    const source = sourcesRef.current.find((candidate) => candidate.id === sourceId);
    if (source) handleOpenSource(source);
  }, [handleOpenSource]);

  const openRedevelopPrompt = useCallback((span: Span, exchange: AIExchangeJSON) => {
    const view = editorViewRef.current;
    if (!view) return;

    const currentSpan = currentSpans(view.state).find((candidate) => candidate.spanId === span.spanId);
    if (!currentSpan) return;
    const text = view.state.doc.sliceString(currentSpan.start, currentSpan.end);
    if (!canRedevelopSpan(currentSpan, text, isAiThinking)) return;

    promptContextRef.current = {
      text,
      from: currentSpan.start,
      to: currentSpan.end,
      imageUrls: extractMarkdownImageUrls(text),
    };
    setPromptValue(promptFromUserInput(exchange.userInput));
    setPromptIntent({
      kind: 'redevelop',
      verb: parseDocumentAIVerb(exchange.verb),
      parentRequestId: currentSpan.requestId ?? exchange.requestId,
      preview: replacementPreview(text),
    });
    setExchangeOverlay(null);
    hideSelectionMenu();
    setShowPrompt(true);
  }, [hideSelectionMenu, isAiThinking]);

  const handleOpenExchangeManifestEntry = useCallback((entry: ExchangeManifestEntry) => {
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

  const provenanceXray = useMemo<Extension>(() => (
    isProvenanceXrayVisible
      ? provenanceXrayExtension({
        sources,
        isAiThinking,
        loadExchange: getExchange,
        onShowExchange: (exchange, span) => setExchangeOverlay({ exchange, span }),
        onRedevelop: openRedevelopPrompt,
        onOpenSource: handleOpenSourceById,
      })
      : []
  ), [handleOpenSourceById, isAiThinking, isProvenanceXrayVisible, openRedevelopPrompt, sources]);

  const marginNotesExtensionValue = useMemo<Extension>(() => marginNotesExtension({
    visible: isMarginNotesVisible,
    onPromote: handlePromoteMarginNote,
    onDismiss: handleDismissMarginNote,
    onUnanchor: (note) => persistMarginNoteStatus(note, 'unanchored'),
  }), [handleDismissMarginNote, handlePromoteMarginNote, isMarginNotesVisible, persistMarginNoteStatus]);

  const selectionDissolveSpanIds = (() => {
    const view = editorViewRef.current;
    if (!isProvenanceXrayVisible || !floatingMenu.visible || !view) return [];
    return spanIdsIntersectingRange(currentSpans(view.state), floatingMenu.selectionFrom, floatingMenu.selectionTo);
  })();

  return (
    <div className="stream-editor">
      <header className="stream-header">
        <button onClick={onBack} className="back-button">
          ← Back
        </button>
        {isEditingTitle ? (
          <input
            ref={titleInputRef}
            type="text"
            className="stream-title-input"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
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
          <span className={`stream-save-status stream-save-status--${saveState}`}>
            {saveState === 'saving' ? 'Saving…' : 'Saved'}
          </span>
          <button
            onClick={() => setIsProvenanceXrayVisible((value) => !value)}
            className={`stream-xray-button ${isProvenanceXrayVisible ? 'stream-xray-button--active' : ''}`}
            title="Toggle provenance x-ray"
            type="button"
            aria-label="Toggle provenance x-ray"
            aria-pressed={isProvenanceXrayVisible}
          >
            <EyeIcon size={16} />
          </button>
          <button
            onClick={() => setIsMarginNotesVisible((value) => !value)}
            className={`stream-margin-button ${isMarginNotesVisible ? 'stream-margin-button--active' : ''}`}
            title="Toggle margin notes"
            type="button"
            aria-label="Toggle margin notes"
            aria-pressed={isMarginNotesVisible}
          >
            <NoteIcon size={16} />
          </button>
          {isMarginNotesVisible && (
            <div className="stream-readback-controls">
              <select
                className="stream-readback-scope"
                value={readBackScope}
                onChange={(event) => setReadBackScope(event.target.value as ReadBackScope)}
                aria-label="Read back scope"
                title="Read back scope"
              >
                <option value="viewport">Viewport</option>
                <option value="section">Section</option>
                <option value="document">Document</option>
              </select>
              <button
                type="button"
                className="stream-readback-button"
                onClick={handleReadBack}
              >
                Read back
              </button>
            </div>
          )}
          <button
            onClick={() => setShowSourcesModal(true)}
            className="stream-sources-button"
            title="Sources"
            type="button"
            aria-label={`Sources, ${sources.length} ${sources.length === 1 ? 'source' : 'sources'}`}
          >
            Sources · {sources.length}
          </button>
          <button
            onClick={() => setShowDeleteConfirm(true)}
            className="delete-stream-button"
            title="Delete stream"
            type="button"
          >
            Delete
          </button>
        </div>
      </header>

      {showDeleteConfirm && (
        <div className="delete-confirm-overlay" onClick={() => setShowDeleteConfirm(false)}>
          <div className="delete-confirm-dialog" onClick={(e) => e.stopPropagation()}>
            <h2>Delete this stream?</h2>
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
                  onDelete();
                }}
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      {showPrompt && (
        <div className="ai-prompt-overlay" onClick={closePrompt}>
          <div className="ai-prompt-dialog" onClick={(e) => e.stopPropagation()}>
            <h2>{promptIntent.kind === 'redevelop' ? 'Re-develop' : 'Ask'}</h2>
            <p>
              {promptIntent.kind === 'redevelop'
                ? `will replace: ${promptIntent.preview}`
                : 'Selection will be attached as context.'}
            </p>
            <textarea
              className="ai-prompt-input"
              value={promptValue}
              onChange={(event) => setPromptValue(event.target.value)}
              onKeyDown={(event) => {
                if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
                  event.preventDefault();
                  handlePromptSend();
                } else if (event.key === 'Escape') {
                  event.preventDefault();
                  closePrompt();
                }
              }}
              placeholder={promptIntent.kind === 'redevelop' ? 'Edit the prompt…' : 'Ask a question or continue the line of thought…'}
              autoFocus
              rows={5}
            />
            <div className="ai-prompt-actions">
              <button
                className="ai-prompt-source-scope"
                type="button"
                onClick={cycleSourceScope}
                title="Cycle source scope"
              >
                Sources: {formatSourceScope(sourceScope)}
              </button>
              <button
                className="ai-prompt-cancel"
                type="button"
                onClick={closePrompt}
              >
                Cancel
              </button>
              <button
                className="ai-prompt-send"
                type="button"
                onClick={handlePromptSend}
                disabled={promptIntent.kind === 'ask' && !promptValue.trim()}
              >
                {promptIntent.kind === 'redevelop' ? 'Re-develop' : 'Ask'}
              </button>
            </div>
          </div>
        </div>
      )}

      {exchangeOverlay && (
        <ExchangeOverlay
          exchange={exchangeOverlay.exchange}
          onClose={() => setExchangeOverlay(null)}
          onRedevelop={() => openRedevelopPrompt(exchangeOverlay.span, exchangeOverlay.exchange)}
          onOpenManifestEntry={handleOpenExchangeManifestEntry}
        />
      )}

      {floatingMenu.visible && (
        <div
          ref={selectionActionMenuRef}
          className="selection-action-menu"
          style={{ left: `${floatingMenu.left}px`, top: `${floatingMenu.top}px` }}
        >
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            title="Ask"
            aria-label="Ask"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionVerb('ask')}
            disabled={isAiThinking}
          >
            Ask
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            title="Challenge"
            aria-label="Challenge"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionVerb('challenge')}
            disabled={isAiThinking}
          >
            Challenge
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            title="Define"
            aria-label="Define"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionVerb('define')}
            disabled={isAiThinking}
          >
            Define
          </button>
          <span className="selection-action-divider" aria-hidden="true" />
          <div className="selection-action-submenu">
            <button
              type="button"
              className="selection-action-button selection-action-button--text selection-action-button--ai"
              title="Rewrite"
              aria-label="Rewrite"
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => setShowRewriteMenu((value) => !value)}
              disabled={isAiThinking}
            >
              Rewrite ▾
            </button>
            {showRewriteMenu && (
              <div className="selection-action-submenu-panel">
                <button
                  type="button"
                  className="selection-action-button selection-action-button--text selection-action-button--wide selection-action-button--ai"
                  title="Develop (replaces)"
                  aria-label="Develop (replaces)"
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => handleSelectionVerb('develop')}
                >
                  Develop (replaces)
                </button>
              </div>
            )}
          </div>
          <span className="selection-action-divider" aria-hidden="true" />
          <button
            type="button"
            className="selection-action-button selection-action-button--format selection-action-button--bold"
            title="Bold"
            aria-label="Bold"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionFormat('**')}
          >
            B
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--format selection-action-button--italic"
            title="Italic"
            aria-label="Italic"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionFormat('*')}
          >
            I
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--format selection-action-button--code"
            title="Code"
            aria-label="Code"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => handleSelectionFormat('`')}
          >
            &lt;/&gt;
          </button>
          {canLinkSelectionToPDF && (
            <button
              type="button"
              className="selection-action-button"
              title="Link to PDF"
              aria-label="Link to PDF"
              onMouseDown={(event) => event.preventDefault()}
              onClick={handleSelectionLinkToPDF}
            >
              <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
                <path d="M8.8 12.9a1 1 0 010-1.4l3.7-3.7a3.4 3.4 0 114.8 4.8l-1.5 1.5-.7-.7 1.5-1.5a2.4 2.4 0 10-3.4-3.4l-3.7 3.7a1 1 0 001.4 1.4l2.5-2.5.7.7-2.5 2.5a2 2 0 01-2.8 0zm-2.1 7a3.4 3.4 0 010-4.8l1.5-1.5.7.7-1.5 1.5a2.4 2.4 0 103.4 3.4l3.7-3.7a1 1 0 00-1.4-1.4l-2.5 2.5-.7-.7 2.5-2.5a2 2 0 112.8 2.8l-3.7 3.7a3.4 3.4 0 01-4.8 0z" />
              </svg>
            </button>
          )}
          {isProvenanceXrayVisible && (
            <>
              <span className="selection-action-divider" aria-hidden="true" />
              <button
                type="button"
                className="selection-action-button selection-action-button--text"
                title="Dissolve provenance in selection"
                aria-label="Dissolve provenance in selection"
                onMouseDown={(event) => event.preventDefault()}
                onClick={handleSelectionDissolve}
                disabled={selectionDissolveSpanIds.length === 0}
              >
                Dissolve
              </button>
            </>
          )}
          <span className="selection-action-divider" aria-hidden="true" />
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-source-scope"
            title="Cycle source scope"
            aria-label="Cycle source scope"
            onMouseDown={(event) => event.preventDefault()}
            onClick={cycleSourceScope}
          >
            Sources: {formatSourceScope(sourceScope)}
          </button>
        </div>
      )}

      {linkPopover.visible && (
        <div
          ref={linkPopoverRef}
          className="link-edit-popover"
          style={{ left: `${linkPopover.left}px`, top: `${linkPopover.top}px` }}
          onBlur={handleLinkPopoverBlur}
        >
          <input
            className="link-edit-input link-edit-input--label"
            value={linkPopover.label}
            aria-label="Link label"
            onChange={(event) => setLinkPopover((previous) => ({ ...previous, label: event.target.value }))}
            onKeyDown={handleLinkPopoverKeyDown}
          />
          <input
            className="link-edit-input link-edit-input--url"
            value={linkPopover.url}
            aria-label="Link URL"
            onChange={(event) => setLinkPopover((previous) => ({ ...previous, url: event.target.value }))}
            onKeyDown={handleLinkPopoverKeyDown}
          />
          <button
            type="button"
            className="link-edit-button"
            onMouseDown={(event) => event.preventDefault()}
            onClick={unlinkLinkPopover}
          >
            Unlink
          </button>
          <button
            type="button"
            className="link-edit-button link-edit-button--remove"
            onMouseDown={(event) => event.preventDefault()}
            onClick={removeLinkPopover}
          >
            Remove
          </button>
        </div>
      )}

      <div className="stream-body">
        <div className="stream-content">
          <div
            ref={editorShellRef}
            className={`document-editor-shell ${isPrepaintHidden ? 'cm-prepaint' : ''}`}
            onDrop={handleDrop}
            onDragOver={handleDragOver}
          >
            <CodeMirror
              value={markdownContent}
              basicSetup={{
                lineNumbers: false,
                foldGutter: false,
                highlightActiveLine: false,
                highlightActiveLineGutter: false,
              }}
              extensions={[
                EditorView.lineWrapping,
                EditorView.contentAttributes.of({
                  spellcheck: 'true',
                  autocapitalize: 'sentences',
                  autocomplete: 'on',
                  autocorrect: 'on',
                }),
                selectionMenuExtension,
                clickToDocumentEndExtension,
                aiWritingExtension,
                editorFindExtension,
                markdown({ base: markdownLanguage, codeLanguages: languages }),
                syntaxHighlighting(markdownHighlightStyle),
                markdownConcealExtension,
                arrivalField,
                provenanceField,
                marginNotesField,
                markdownImageWidgetExtension,
                provenanceXray,
                marginNotesExtensionValue,
                tickerPDFLinkExtension(stream.id),
                linkInteraction,
              ]}
              onCreateEditor={(view) => {
                editorViewRef.current = view;
                view.dispatch({
                  effects: setSpans.of(payloadSpansForDoc(stream.spans, view.state.doc.toString())),
                  annotations: Transaction.addToHistory.of(false),
                });
                applyMarginNotesToEditor(stream.marginNotes);

                scrollCleanupRef.current?.();
                const handleScroll = () => scheduleScrollPositionSave();
                view.scrollDOM.addEventListener('scroll', handleScroll, { passive: true });
                scrollCleanupRef.current = () => view.scrollDOM.removeEventListener('scroll', handleScroll);

                clearRevealFrame();
                const scrollOffset = Math.max(0, Number(stream.document?.scrollOffset ?? 0));
                ensureSyntaxTree(view.state, restoreViewportEnd(view, scrollOffset), 50);
                view.scrollDOM.scrollTop = scrollOffset;
                revealFrameRef.current = window.requestAnimationFrame(() => {
                  revealFrameRef.current = window.requestAnimationFrame(() => {
                    revealFrameRef.current = null;
                    if (editorViewRef.current === view) {
                      setIsPrepaintHidden(false);
                    }
                  });
                });

              }}
              onChange={(value) => {
                setMarkdownContent(value);
              }}
              className="document-editor-codemirror"
            />
            {aiFeedback.visible && (
              <div
                className={`document-ai-status-pill document-ai-status-pill--${aiFeedback.kind}`}
                role="status"
                aria-live="polite"
              >
                <span className="document-ai-status-dot" aria-hidden="true" />
                <span>{aiFeedback.message}</span>
                {isAiThinking && aiFeedback.kind === 'writing' && (
                  <button
                    type="button"
                    className="document-ai-stop-button"
                    onClick={handleStopDocumentAI}
                  >
                    <XIcon size={12} /> Stop
                  </button>
                )}
              </div>
            )}
            {sourceIndexNotice && (
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
        onSourceRemoved={handleSourceRemoved}
        onSourceAIExclusionChanged={handleSourceAIExclusionChanged}
        onSourceOpen={handleOpenSource}
        highlightedSourceId={highlightedSourceId || pendingSourceId}
        onClearHighlight={() => {
          setHighlightedSourceId(null);
          onClearPendingSource?.();
        }}
      />

    </div>
  );
}
