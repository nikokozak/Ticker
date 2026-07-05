import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { EditorView } from '@codemirror/view';
import { Transaction, type Extension } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { bridge, type Stream, type SourceReference, type DocumentAICitation, type DocumentAISourceContextMode } from '../types';
import { SourcesModal } from './SourcesModal';
import { SearchModal } from './SearchModal';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';
import { AI_HISTORY_USER_EVENT, aiWritingExtension, getAiWritingRange, setAiWritingRangeEffect } from '../extensions/AIWritingState';
import { markdownConcealExtension } from '../extensions/MarkdownConceal';
import { buildMarkdownImageToken, extractMarkdownImageUrls, markdownImageWidgetExtension } from '../extensions/MarkdownImageWidget';
import { tickerPDFLinkExtension } from '../extensions/PDFHighlightLink';
import { computeAppendInsertion } from '../utils/appendInsertion';
import { buildProvenanceLine, swapCitationMarkersWithMetadata } from '../utils/citationMarkers';
import { debugWarn } from '../utils/debug';
import {
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
  onNavigateToStream?: (streamId: string, targetId: string, targetType?: 'cell' | 'source') => void;
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

interface FloatingMenuState {
  visible: boolean;
  left: number;
  top: number;
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
}

const SELECTION_MENU_DELAY_MS = 180;
const AI_ERROR_FEEDBACK_MS = 2200;
const AI_INDEXING_NOTICE_MS = 4000;

export type SourceScope = 'auto' | 'all' | 'none';

const sourceScopeByStreamId = new Map<string, SourceScope>();

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

const markdownHighlightStyle = HighlightStyle.define([
  {
    tag: t.heading,
    color: 'var(--text)',
    textDecoration: 'none',
    fontWeight: '620',
  },
  {
    tag: t.heading1,
    fontSize: 'var(--editor-heading-1)',
    fontWeight: '650',
  },
  {
    tag: t.heading2,
    fontSize: 'var(--editor-heading-2)',
    fontWeight: '640',
  },
  {
    tag: t.heading3,
    fontSize: 'var(--editor-heading-3)',
    fontWeight: '630',
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
    fontWeight: '640',
  },
  {
    tag: t.monospace,
    color: 'var(--color-text-secondary)',
    fontFamily: 'var(--font-mono)',
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
  onNavigateToStream,
  pendingCellId,
  pendingSourceId,
  onClearPendingCell,
  onClearPendingSource,
}: StreamEditorProps) {
  const addToast = useToastStore((state) => state.addToast);

  const [title, setTitle] = useState(stream.title);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [showSourcesModal, setShowSourcesModal] = useState(false);
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [markdownContent, setMarkdownContent] = useState(stream.document?.markdown ?? '');
  const [showPrompt, setShowPrompt] = useState(false);
  const [promptValue, setPromptValue] = useState('');
  const [sourceScope, setSourceScope] = useState<SourceScope>(
    () => sourceScopeByStreamId.get(stream.id) ?? 'auto'
  );
  const [aiStatus, setAiStatus] = useState<'idle' | 'thinking'>('idle');
  const [floatingMenu, setFloatingMenu] = useState<FloatingMenuState>({
    visible: false,
    left: 0,
    top: 0,
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
  const lastSavedContentRef = useRef(stream.document?.markdown ?? '');
  const markdownContentRef = useRef(stream.document?.markdown ?? '');
  const revisionRef = useRef(stream.document?.revision ?? 0);
  const promptContextRef = useRef<SelectionContext | null>(null);
  const selectionMenuTimerRef = useRef<number | null>(null);
  const aiFeedbackTimerRef = useRef<number | null>(null);
  const sourceIndexNoticeTimerRef = useRef<number | null>(null);
  const pendingPDFAnchorSelectionRef = useRef<PendingPDFAnchorSelection | null>(null);
  const sourcesRef = useRef<SourceReference[]>(stream.sources);
  const sourceIndexStatusesRef = useRef<Map<string, SourceReference['indexStatus']>>(new Map());
  const showPromptRef = useRef(showPrompt);
  const isAiThinkingRef = useRef(false);
  const aiRequestRef = useRef<{
    id: string;
    buffer: string;
    mode: 'replace' | 'after';
    originalText: string;
    prefix: string;
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

  const cycleSourceScope = useCallback(() => {
    setSourceScope((previous) => {
      const next = nextSourceScope(previous);
      sourceScopeByStreamId.set(stream.id, next);
      return next;
    });
  }, [stream.id]);

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
    setFloatingMenu({ visible: false, left: 0, top: 0 });
    setShowPrompt(false);
    setPromptValue('');
    setSourceScope(sourceScopeByStreamId.get(stream.id) ?? 'auto');
    promptContextRef.current = null;
    aiRequestRef.current = null;
    const view = editorViewRef.current;
    if (view) {
      dispatchAiRangeClear(view);
    }
  }, [clearSourceIndexNoticeTimer, hideAiFeedback, stream.id, stream.document?.markdown, stream.document?.revision, stream.title]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const view = editorViewRef.current;
      if (view) {
        focusEditorAtDocumentEnd(view);
      }
    }, 0);

    return () => window.clearTimeout(timer);
  }, [stream.id]);

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

      void bridge.sendAsync<{ revision: number }>('saveStreamDocument', {
        streamId: stream.id,
        markdown: contentToSave,
        baseRevision,
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
        if (view) {
          view.dispatch({
            changes: { from: 0, to: view.state.doc.length, insert: markdown },
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

        if (view) {
          view.dispatch({
            changes: { from: insertion.from, insert },
            effects: EditorView.scrollIntoView(insertion.insertedEnd, { y: 'nearest' }),
          });
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
        return;
      }

      if (message.type === 'documentAIError') {
        const requestId = message.payload?.requestId as string | undefined;
        const error = message.payload?.error as string | undefined;
        if (!requestId || requestId !== active.id) return;

        const errorCode = message.payload?.errorCode as string | undefined;
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
            changes: { from: range.from, to: range.to, insert: active.originalText },
            selection: { anchor: range.from + active.originalText.length },
            effects: setAiWritingRangeEffect.of(null),
            annotations: Transaction.addToHistory.of(false),
          });
          view.focus();
        } else if (view) {
          dispatchAiRangeClear(view);
        }

        setAiStatus('idle');
        aiRequestRef.current = null;
        showAiErrorFeedback(displayError);
        addToast(displayError, 'error');
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

        const suffix = active.mode === 'after' && !finalOutput.endsWith('\n') ? '\n' : '';
        const insertText = `${active.prefix}${finalOutput}${suffix}`;
        const finalFrom = range.from;
        const originalTo = finalFrom + active.originalText.length;

        view.dispatch({
          changes: { from: range.from, to: range.to, insert: active.originalText },
          annotations: Transaction.addToHistory.of(false),
        });

        view.dispatch({
          changes: { from: finalFrom, to: originalTo, insert: insertText },
          selection: { anchor: finalFrom + insertText.length },
          effects: setAiWritingRangeEffect.of(null),
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
      const sourceName = message.payload?.sourceName as string | undefined;
      const highlightId = message.payload?.highlightId as string | undefined;
      const page = message.payload?.page as number | undefined;
      const quote = message.payload?.quote as string | undefined;

      if (!sourceId || !highlightId) return;

      const pageNumber = Number.isFinite(page) ? Math.max(1, Math.round(page as number)) : 1;
      const linkUrl = `ticker-pdf://${sourceId}?highlight=${encodeURIComponent(highlightId)}&page=${pageNumber}`;
      const compactQuote = (quote || '').trim().replace(/\s+/g, ' ');
      const quoteLine = compactQuote ? `> ${compactQuote}\n` : '';
      const linkLabel = `${sourceName || 'PDF'} p.${pageNumber}`;
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
          sourceName: message.payload?.sourceName as string | undefined,
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
    bridge.send({
      type: 'updateStreamTitle',
      payload: { id: stream.id, title: trimmedTitle },
    });
  }, [title, stream.id]);

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
    setFloatingMenu((previous) => (previous.visible ? { ...previous, visible: false } : previous));
  }, [clearSelectionMenuTimer]);

  const getSelectionMenuPlacement = useCallback((view: EditorView): { left: number; top: number } | null => {
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
      menuSize: {
        width: menu?.offsetWidth,
        height: menu?.offsetHeight,
      },
      viewportHeight: window.innerHeight,
    });
  }, []);

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
      });
    }, SELECTION_MENU_DELAY_MS);
  }, [clearSelectionMenuTimer, getSelectionMenuPlacement, hideSelectionMenu]);

  useEffect(() => {
    showPromptRef.current = showPrompt;
    isAiThinkingRef.current = isAiThinking;

    if (showPrompt || isAiThinking) {
      hideSelectionMenu();
    }
  }, [hideSelectionMenu, isAiThinking, showPrompt]);

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
      originalText,
      prefix,
    };
    setAiStatus('thinking');
    showAiWritingFeedback();

    const indexingSource = sourcesRef.current.find((source) => {
      const status = sourceIndexStatusesRef.current.get(source.id) ?? source.indexStatus;
      return status === 'indexing' || status === 'pending';
    });
    if (indexingSource) {
      showSourceIndexNotice(indexingSource.displayName);
    }

    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: options.query,
        context: options.context,
        sourceScope,
        imageURLs: options.imageUrls ?? [],
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
    });
    hideSelectionMenu();
  }, [addToast, getSelectionContext, hideSelectionMenu, startDocumentAI]);

  const openPromptWithContext = useCallback((context: SelectionContext) => {
    hideSelectionMenu();
    promptContextRef.current = context;
    setPromptValue('');
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

  const canLinkSelectionToPDF = pdfPaneState.visible && pdfPaneState.streamId === stream.id;

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

  const handleSelectionSend = useCallback(() => {
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
      mode: 'replace',
    });
    hideSelectionMenu();
  }, [getSelectionContext, hideSelectionMenu, startDocumentAI]);

  const handleSelectionPrompt = useCallback(() => {
    const context = getSelectionContext(false);
    if (!context || !context.text.trim()) {
      hideSelectionMenu();
      return;
    }
    openPromptWithContext(context);
  }, [getSelectionContext, hideSelectionMenu, openPromptWithContext]);

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
    bridge.send({
      type: 'beginPdfAnchorPick',
      payload: { streamId: stream.id },
    });
  }, [addToast, canLinkSelectionToPDF, getSelectionContext, hideSelectionMenu, stream.id]);

  const closePrompt = useCallback(() => {
    setShowPrompt(false);
    setPromptValue('');
    promptContextRef.current = null;
    hideSelectionMenu();
  }, [hideSelectionMenu]);

  const handlePromptSend = useCallback(() => {
    const prompt = promptValue.trim();
    const context = promptContextRef.current;
    if (!prompt || !context) return;

    closePrompt();

    startDocumentAI({
      query: prompt,
      context: context.text.trim(),
      imageUrls: context.imageUrls,
      from: context.from,
      to: context.to,
      mode: 'after',
    });
  }, [closePrompt, promptValue, startDocumentAI]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setShowSearch(true);
        return;
      }
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

  const handleOpenSource = useCallback((source: SourceReference) => {
    bridge.send({
      type: 'openSource',
      payload: { sourceId: source.id },
    });
  }, []);

  const handleNavigateToCell = useCallback(() => {
    addToast('Cell anchors are not available in document editor mode yet.', 'info');
  }, [addToast]);

  const handleNavigateToSource = useCallback((sourceId: string) => {
    if (!sources.some((source) => source.id === sourceId)) {
      addToast('Source is not attached to this stream.', 'info');
      return;
    }
    setHighlightedSourceId(sourceId);
    setShowSourcesModal(true);
  }, [addToast, sources]);

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
          <h1 onClick={startEditingTitle} className="stream-title-editable">
            {title}
          </h1>
        )}
        <span className={`stream-save-status stream-save-status--${saveState}`}>
          {saveState === 'saving' ? 'Saving…' : 'Saved'}
        </span>
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
            <h2>Send &amp; Prompt</h2>
            <p>Selection will be attached as context. Write a prompt for the AI.</p>
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
              placeholder="Ask the AI to summarize, rewrite, or expand the selected text…"
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
                disabled={!promptValue.trim()}
              >
                Send
              </button>
            </div>
          </div>
        </div>
      )}

      {floatingMenu.visible && (
        <div
          ref={selectionActionMenuRef}
          className="selection-action-menu"
          style={{ left: `${floatingMenu.left}px`, top: `${floatingMenu.top}px` }}
        >
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
          <span className="selection-action-divider" aria-hidden="true" />
          <button
            type="button"
            className="selection-action-button"
            title="Send"
            aria-label="Send"
            onMouseDown={(event) => event.preventDefault()}
            onClick={handleSelectionSend}
            disabled={isAiThinking}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
              <path d="M3.2 4.2l17.6 7.8-17.6 7.8 2.4-7-2.4-8.6zm2.8 2.7 1.3 4.7h7.8v1h-7.8L6 17.1l11.8-5.1L6 6.9z" />
            </svg>
          </button>
          <button
            type="button"
            className="selection-action-button"
            title="Send & Prompt"
            aria-label="Send and prompt"
            onMouseDown={(event) => event.preventDefault()}
            onClick={handleSelectionPrompt}
            disabled={isAiThinking}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
              <path d="M4 3h16a1 1 0 011 1v11a1 1 0 01-1 1H8l-4 4v-4H4a1 1 0 01-1-1V4a1 1 0 011-1zm1 2v9h1v1.6L7.6 14H19V5H5zm3 2h8v1H8V7zm0 3h5v1H8v-1z" />
            </svg>
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
        </div>
      )}

      <div className="stream-body">
        <div className="stream-content">
          <div
            ref={editorShellRef}
            className="document-editor-shell"
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
                markdown({ base: markdownLanguage, codeLanguages: languages }),
                syntaxHighlighting(markdownHighlightStyle),
                markdownConcealExtension,
                markdownImageWidgetExtension,
                tickerPDFLinkExtension(stream.id),
              ]}
              onCreateEditor={(view) => {
                editorViewRef.current = view;
                window.setTimeout(() => {
                  if (editorViewRef.current === view) {
                    focusEditorAtDocumentEnd(view);
                  }
                }, 0);
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
        onSourceOpen={handleOpenSource}
        highlightedSourceId={highlightedSourceId || pendingSourceId}
        onClearHighlight={() => {
          setHighlightedSourceId(null);
          onClearPendingSource?.();
        }}
      />

      <SearchModal
        isOpen={showSearch}
        onClose={() => setShowSearch(false)}
        currentStreamId={stream.id}
        onNavigateToCell={handleNavigateToCell}
        onNavigateToStream={onNavigateToStream || (() => {})}
        onNavigateToSource={handleNavigateToSource}
      />
    </div>
  );
}
