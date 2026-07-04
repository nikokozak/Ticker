import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { EditorView } from '@codemirror/view';
import { Transaction, type Extension } from '@codemirror/state';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { bridge, Stream, SourceReference } from '../types';
import { SidePanel } from './SidePanel';
import { SearchModal } from './SearchModal';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';
import { markdownConcealExtension } from '../extensions/MarkdownConceal';
import { buildMarkdownImageToken, extractMarkdownImageUrls, markdownImageWidgetExtension } from '../extensions/MarkdownImageWidget';

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

const SELECTION_MENU_DELAY_MS = 180;
const SELECTION_MENU_GAP = 10;
const SELECTION_MENU_HORIZONTAL_INSET = 8;
const DEFAULT_SELECTION_MENU_WIDTH = 82;
const DEFAULT_SELECTION_MENU_HEIGHT = 44;

const markdownHighlightStyle = HighlightStyle.define([
  {
    tag: t.heading,
    color: 'var(--color-text)',
    textDecoration: 'none',
    fontWeight: '620',
  },
  {
    tag: t.heading1,
    fontSize: '1.26em',
    fontWeight: '650',
  },
  {
    tag: t.heading2,
    fontSize: '1.16em',
    fontWeight: '640',
  },
  {
    tag: t.heading3,
    fontSize: '1.08em',
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
    color: 'var(--color-text)',
    fontStyle: 'italic',
  },
  {
    tag: t.strong,
    color: 'var(--color-text)',
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
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [markdownContent, setMarkdownContent] = useState(stream.document?.markdown ?? '');
  const [showPrompt, setShowPrompt] = useState(false);
  const [promptValue, setPromptValue] = useState('');
  const [aiStatus, setAiStatus] = useState<'idle' | 'thinking'>('idle');
  const [floatingMenu, setFloatingMenu] = useState<FloatingMenuState>({
    visible: false,
    left: 0,
    top: 0,
  });

  const titleInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const editorViewRef = useRef<EditorView | null>(null);
  const selectionActionMenuRef = useRef<HTMLDivElement>(null);
  const lastSavedContentRef = useRef(stream.document?.markdown ?? '');
  const promptContextRef = useRef<SelectionContext | null>(null);
  const selectionMenuTimerRef = useRef<number | null>(null);
  const showPromptRef = useRef(showPrompt);
  const isAiThinkingRef = useRef(false);
  const aiRequestRef = useRef<{
    id: string;
    buffer: string;
    from: number;
    to: number;
    mode: 'replace' | 'after';
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
  const pdfSources = useMemo(
    () => sources.filter((source) => source.fileType === 'pdf'),
    [sources],
  );
  const hasPdfSources = pdfSources.length > 0;

  const isAiThinking = aiStatus === 'thinking';

  const isEditorActive = useCallback(() => {
    const shell = editorShellRef.current;
    const active = document.activeElement;
    if (!shell || !active) return false;
    return shell.contains(active);
  }, []);

  useEffect(() => {
    setMarkdownContent(stream.document?.markdown ?? '');
    lastSavedContentRef.current = stream.document?.markdown ?? '';
    setTitle(stream.title);
    setSaveState('saved');
    setAiStatus('idle');
    setFloatingMenu({ visible: false, left: 0, top: 0 });
    setShowPrompt(false);
    setPromptValue('');
    promptContextRef.current = null;
    aiRequestRef.current = null;
  }, [stream.id, stream.document?.markdown, stream.title]);

  useEffect(() => {
    if (!pendingSourceId) return;
    if (pdfSources.some((source) => source.id === pendingSourceId)) {
      setHighlightedSourceId(pendingSourceId);
    }
  }, [pdfSources, pendingSourceId]);

  useEffect(() => {
    if (hasPdfSources) return;
    setHighlightedSourceId(null);
    onClearPendingSource?.();
  }, [hasPdfSources, onClearPendingSource]);

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
      bridge.send({
        type: 'saveStreamDocument',
        payload: {
          streamId: stream.id,
          markdown: markdownContent,
        },
      });
      lastSavedContentRef.current = markdownContent;
      setSaveState('saved');
    }, 350);

    return () => window.clearTimeout(timer);
  }, [markdownContent, stream.id]);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'streamDocumentAppended') {
        const payloadStreamId = message.payload?.streamId as string | undefined;
        const fragment = message.payload?.fragment as string | undefined;

        if (!payloadStreamId || payloadStreamId !== stream.id || typeof fragment !== 'string' || fragment.length === 0) {
          return;
        }

        const view = editorViewRef.current;
        if (!view) return;

        const end = view.state.doc.length;
        const sep = end > 0 ? '\n\n' : '';
        const insert = `${sep}${fragment}`;
        const insertedEnd = end + insert.length;

        view.dispatch({
          changes: { from: end, insert },
          effects: EditorView.scrollIntoView(insertedEnd, { y: 'nearest' }),
        });
        setMarkdownContent(view.state.doc.toString());
        return;
      }

      const active = aiRequestRef.current;
      if (!active) return;

      if (message.type === 'documentAIChunk') {
        const requestId = message.payload?.requestId as string | undefined;
        const chunk = message.payload?.chunk as string | undefined;
        if (!requestId || requestId !== active.id || !chunk) return;
        active.buffer += chunk;
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

        setAiStatus('idle');
        aiRequestRef.current = null;
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
          return;
        }

        const rawOutput = active.buffer.trim();
        if (!rawOutput) {
          setAiStatus('idle');
          aiRequestRef.current = null;
          addToast('AI returned empty output.', 'warning');
          return;
        }

        let insertText = rawOutput;
        let from = active.from;
        let to = active.to;

        if (active.mode === 'after') {
          const doc = view.state.doc;
          const before = doc.sliceString(Math.max(0, active.to - 2), active.to);
          const needsBlankLine = !before.endsWith('\n\n');
          const needsSingleBreak = before.endsWith('\n') && !before.endsWith('\n\n');
          const prefix = needsBlankLine ? '\n\n' : needsSingleBreak ? '\n' : '';
          const suffix = insertText.endsWith('\n') ? '' : '\n';
          insertText = `${prefix}${insertText}${suffix}`;
          from = active.to;
          to = active.to;
        }

        view.dispatch({
          changes: { from, to, insert: insertText },
          selection: { anchor: from + insertText.length },
          annotations: Transaction.addToHistory.of(true),
        });
        view.focus();

        setAiStatus('idle');
        aiRequestRef.current = null;
        return;
      }
    });

    return () => unsubscribe();
  }, [addToast, stream.id]);

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
    const menuWidth = menu?.offsetWidth ?? DEFAULT_SELECTION_MENU_WIDTH;
    const menuHeight = menu?.offsetHeight ?? DEFAULT_SELECTION_MENU_HEIGHT;
    const rawLeft = (coords.left + coords.right) / 2;
    const minEdge = shellRect.left + SELECTION_MENU_HORIZONTAL_INSET;
    const maxEdge = shellRect.right - SELECTION_MENU_HORIZONTAL_INSET;
    const availableWidth = maxEdge - minEdge;

    const left = availableWidth > menuWidth
      ? Math.min(maxEdge - menuWidth / 2, Math.max(minEdge + menuWidth / 2, rawLeft))
      : minEdge + availableWidth / 2;

    const topBoundary = Math.max(0, shellRect.top) + SELECTION_MENU_HORIZONTAL_INSET;
    const bottomBoundary = Math.min(window.innerHeight, shellRect.bottom) - SELECTION_MENU_HORIZONTAL_INSET;
    const aboveTop = coords.top - menuHeight - SELECTION_MENU_GAP;
    const belowTop = coords.bottom + SELECTION_MENU_GAP;
    const maxTop = Math.max(topBoundary, bottomBoundary - menuHeight);
    const top = aboveTop >= topBoundary
      ? aboveTop
      : Math.min(Math.max(belowTop, topBoundary), maxTop);

    return { left, top };
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

    const requestId = crypto.randomUUID();
    aiRequestRef.current = {
      id: requestId,
      buffer: '',
      from: options.from,
      to: options.to,
      mode: options.mode,
    };
    setAiStatus('thinking');

    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: options.query,
        context: options.context,
        imageURLs: options.imageUrls ?? [],
      },
    });
  }, [addToast, isAiThinking, stream.id]);

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
    if (!pdfSources.some((source) => source.id === sourceId)) {
      addToast('Source panel is available for PDF sources only.', 'info');
      return;
    }
    setHighlightedSourceId(sourceId);
  }, [addToast, pdfSources]);

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
                EditorView.editable.of(!isAiThinking),
                selectionMenuExtension,
                markdown({ base: markdownLanguage, codeLanguages: languages }),
                syntaxHighlighting(markdownHighlightStyle),
                markdownConcealExtension,
                markdownImageWidgetExtension,
              ]}
              onCreateEditor={(view) => {
                editorViewRef.current = view;
              }}
              onChange={(value) => {
                setMarkdownContent(value);
              }}
              className="document-editor-codemirror"
            />
          </div>
        </div>
        {hasPdfSources && (
          <div className="stream-sources-dock">
            <SidePanel
              streamId={stream.id}
              sources={pdfSources}
              onSourceRemoved={handleSourceRemoved}
              onSourceOpen={handleOpenSource}
              highlightedSourceId={highlightedSourceId || pendingSourceId}
              onClearHighlight={() => {
                setHighlightedSourceId(null);
                onClearPendingSource?.();
              }}
            />
          </div>
        )}
      </div>

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
