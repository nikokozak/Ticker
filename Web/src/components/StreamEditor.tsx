import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { EditorView } from '@codemirror/view';
import { Transaction } from '@codemirror/state';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { bridge, Stream, SourceReference } from '../types';
import { SidePanel } from './SidePanel';
import { SearchModal } from './SearchModal';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';
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

interface EditorChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  status?: 'streaming' | 'complete' | 'error';
  modelId?: string;
}

interface ChatAIRequestState {
  id: string;
  buffer: string;
  assistantMessageId: string;
}

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
  const [showInspector, setShowInspector] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [markdownContent, setMarkdownContent] = useState(stream.document?.markdown ?? '');
  const [showPrompt, setShowPrompt] = useState(false);
  const [promptValue, setPromptValue] = useState('');
  const [aiStatus, setAiStatus] = useState<'idle' | 'thinking'>('idle');
  const [isChatOpen, setIsChatOpen] = useState(false);
  const [isChatMinimized, setIsChatMinimized] = useState(false);
  const [chatMessages, setChatMessages] = useState<EditorChatMessage[]>([]);
  const [chatInputValue, setChatInputValue] = useState('');
  const [chatContext, setChatContext] = useState<SelectionContext | null>(null);
  const [isChatThinking, setIsChatThinking] = useState(false);
  const [floatingMenu, setFloatingMenu] = useState<FloatingMenuState>({
    visible: false,
    left: 0,
    top: 0,
  });

  const titleInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const editorViewRef = useRef<EditorView | null>(null);
  const chatMessagesRef = useRef<HTMLDivElement>(null);
  const lastSavedContentRef = useRef(stream.document?.markdown ?? '');
  const promptContextRef = useRef<SelectionContext | null>(null);
  const selectionMenuTimerRef = useRef<number | null>(null);
  const aiRequestRef = useRef<{
    id: string;
    buffer: string;
    from: number;
    to: number;
    mode: 'replace' | 'after';
  } | null>(null);
  const chatAiRequestRef = useRef<ChatAIRequestState | null>(null);

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

  const editorAPI = useMemo<EditorAPI>(() => ({
    replaceCellHtml: () => {
      // Document editor mode: cell updates are ignored.
    },
    insertImage: (imageUrl: string) => insertImageAtCursor(imageUrl),
  }), [insertImageAtCursor]);

  const { sources, setSources } = useBridgeMessages({
    streamId: stream.id,
    initialSources: stream.sources,
    editorAPI,
  });

  const isAiThinking = aiStatus === 'thinking';
  const isAnyAiThinking = isAiThinking || isChatThinking;

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
    setIsChatOpen(false);
    setIsChatMinimized(false);
    setChatMessages([]);
    setChatInputValue('');
    setChatContext(null);
    setIsChatThinking(false);
    setFloatingMenu({ visible: false, left: 0, top: 0 });
    setShowPrompt(false);
    setPromptValue('');
    promptContextRef.current = null;
    aiRequestRef.current = null;
    chatAiRequestRef.current = null;
  }, [stream.id, stream.document?.markdown, stream.title]);

  useEffect(() => {
    if (pendingSourceId) {
      setShowInspector(true);
    }
  }, [pendingSourceId]);

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

  const formatAIError = useCallback((payload: Record<string, unknown> | undefined, fallbackError?: string) => {
    const error = (payload?.error as string | undefined) ?? fallbackError;
    const errorCode = payload?.errorCode as string | undefined;
    const proxyRequestId = payload?.proxyRequestId as string | undefined;
    let displayError = error || 'AI request failed.';

    if (errorCode === 'quota_exceeded') {
      const scope = payload?.quotaScope as string | undefined;
      const resetAt = payload?.quotaResetAt as string | undefined;
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
      const retryAfter = payload?.retryAfter as number | undefined;
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

    return displayError;
  }, []);

  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      const documentRequest = aiRequestRef.current;
      const chatRequest = chatAiRequestRef.current;

      if (message.type === 'documentAIChunk') {
        const requestId = message.payload?.requestId as string | undefined;
        const chunk = message.payload?.chunk as string | undefined;
        if (!requestId || !chunk) return;

        if (documentRequest && requestId === documentRequest.id) {
          documentRequest.buffer += chunk;
          return;
        }

        if (chatRequest && requestId === chatRequest.id) {
          chatRequest.buffer += chunk;
          setChatMessages((previous) => previous.map((entry) => (
            entry.id === chatRequest.assistantMessageId
              ? { ...entry, content: chatRequest.buffer, status: 'streaming' }
              : entry
          )));
        }
        return;
      }

      if (message.type === 'documentModelSelected') {
        const requestId = message.payload?.requestId as string | undefined;
        const modelId = message.payload?.modelId as string | undefined;
        if (!requestId || !modelId) return;

        if (chatRequest && requestId === chatRequest.id) {
          setChatMessages((previous) => previous.map((entry) => (
            entry.id === chatRequest.assistantMessageId
              ? { ...entry, modelId }
              : entry
          )));
        }
        return;
      }

      if (message.type === 'documentAIError') {
        const requestId = message.payload?.requestId as string | undefined;
        if (!requestId) return;

        if (documentRequest && requestId === documentRequest.id) {
          setAiStatus('idle');
          aiRequestRef.current = null;
          addToast(formatAIError(message.payload), 'error');
          return;
        }

        if (chatRequest && requestId === chatRequest.id) {
          setIsChatThinking(false);
          chatAiRequestRef.current = null;
          const messageText = formatAIError(message.payload);
          setChatMessages((previous) => previous.map((entry) => (
            entry.id === chatRequest.assistantMessageId
              ? { ...entry, content: messageText, status: 'error' }
              : entry
          )));
          addToast(messageText, 'error');
        }
        return;
      }

      if (message.type === 'documentAIComplete') {
        const requestId = message.payload?.requestId as string | undefined;
        if (!requestId) return;

        if (documentRequest && requestId === documentRequest.id) {
          const view = editorViewRef.current;
          if (!view) {
            setAiStatus('idle');
            aiRequestRef.current = null;
            return;
          }

          const rawOutput = documentRequest.buffer.trim();
          if (!rawOutput) {
            setAiStatus('idle');
            aiRequestRef.current = null;
            addToast('AI returned empty output.', 'warning');
            return;
          }

          let insertText = rawOutput;
          let from = documentRequest.from;
          let to = documentRequest.to;

          if (documentRequest.mode === 'after') {
            const doc = view.state.doc;
            const before = doc.sliceString(Math.max(0, documentRequest.to - 2), documentRequest.to);
            const needsBlankLine = !before.endsWith('\n\n');
            const needsSingleBreak = before.endsWith('\n') && !before.endsWith('\n\n');
            const prefix = needsBlankLine ? '\n\n' : needsSingleBreak ? '\n' : '';
            const suffix = insertText.endsWith('\n') ? '' : '\n';
            insertText = `${prefix}${insertText}${suffix}`;
            from = documentRequest.to;
            to = documentRequest.to;
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

        if (chatRequest && requestId === chatRequest.id) {
          setIsChatThinking(false);
          chatAiRequestRef.current = null;
          setChatMessages((previous) => previous.map((entry) => (
            entry.id === chatRequest.assistantMessageId
              ? {
                  ...entry,
                  content: chatRequest.buffer.trim() || 'AI returned empty output.',
                  status: 'complete',
                }
              : entry
          )));
        }
      }
    });

    return () => unsubscribe();
  }, [addToast, formatAIError]);

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
      const text = doc.sliceString(selection.from, selection.to);
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
    let text = doc.sliceString(from, to).trim();

    if (!text) {
      text = doc.toString().trim();
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

  const insertTextAtCursor = useCallback((content: string) => {
    const text = content.trim();
    if (!text) return;

    const view = editorViewRef.current;
    if (!view) {
      setMarkdownContent((previous) => `${previous}${previous.endsWith('\n') ? '' : '\n'}${text}\n`);
      return;
    }

    const selection = view.state.selection.main;
    const before = view.state.doc.sliceString(Math.max(0, selection.from - 1), selection.from);
    const prefix = before && !before.endsWith('\n') ? '\n' : '';
    const suffix = text.endsWith('\n') ? '' : '\n';
    const snippet = `${prefix}${text}${suffix}`;

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

  const getActiveSelectionForChat = useCallback(() => {
    const selection = getSelectionContext(false);
    if (!selection || !selection.text.trim()) return null;
    return selection;
  }, [getSelectionContext]);

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

  const getFloatingMenuPlacement = useCallback((): { left: number; top: number } | null => {
    const shell = editorShellRef.current;
    if (!shell) return null;

    const domSelection = window.getSelection();
    if (!domSelection || domSelection.rangeCount === 0) return null;
    if (!domSelection.anchorNode || !domSelection.focusNode) return null;
    if (!shell.contains(domSelection.anchorNode) || !shell.contains(domSelection.focusNode)) return null;
    if (domSelection.isCollapsed) return null;

    const range = domSelection.getRangeAt(0);
    const rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return null;

    const horizontalPadding = 16;
    const left = Math.min(
      window.innerWidth - horizontalPadding,
      Math.max(horizontalPadding, rect.left + rect.width / 2),
    );
    const top = rect.bottom + 10;

    return { left, top };
  }, []);

  const scheduleSelectionMenu = useCallback(() => {
    clearSelectionMenuTimer();
    if (showPrompt || isAnyAiThinking || (isChatOpen && !isChatMinimized)) {
      setFloatingMenu((previous) => (previous.visible ? { ...previous, visible: false } : previous));
      return;
    }

    selectionMenuTimerRef.current = window.setTimeout(() => {
      const selection = getSelectionContext(false);
      const placement = getFloatingMenuPlacement();
      if (!selection || !selection.text.trim() || !placement) {
        setFloatingMenu((previous) => (previous.visible ? { ...previous, visible: false } : previous));
        return;
      }
      setFloatingMenu({
        visible: true,
        left: placement.left,
        top: placement.top,
      });
    }, 180);
  }, [
    clearSelectionMenuTimer,
    getFloatingMenuPlacement,
    getSelectionContext,
    isAnyAiThinking,
    isChatMinimized,
    isChatOpen,
    showPrompt,
  ]);

  const startDocumentAI = useCallback((options: {
    query: string;
    context?: string;
    imageUrls?: string[];
    from: number;
    to: number;
    mode: 'replace' | 'after';
  }) => {
    if (isAnyAiThinking) {
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
  }, [addToast, isAnyAiThinking, stream.id]);

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
    if (isAnyAiThinking) {
      addToast('AI is already running for this stream.', 'info');
      return;
    }
    const context = getSelectionContext(true);
    if (!context || !context.text.trim()) {
      addToast('Select text or place the cursor in a paragraph to use as context.', 'info');
      return;
    }
    openPromptWithContext(context);
  }, [addToast, getSelectionContext, isAnyAiThinking, openPromptWithContext]);

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

  const openEditorChat = useCallback(() => {
    const selection = getActiveSelectionForChat();
    setIsChatOpen(true);
    setIsChatMinimized(false);
    setChatContext((previous) => selection ?? previous);
    hideSelectionMenu();
  }, [getActiveSelectionForChat, hideSelectionMenu]);

  const minimizeEditorChat = useCallback(() => {
    setIsChatMinimized(true);
  }, []);

  const restoreEditorChat = useCallback(() => {
    setIsChatOpen(true);
    setIsChatMinimized(false);
  }, []);

  const closeEditorChat = useCallback(() => {
    setIsChatOpen(false);
    setIsChatMinimized(false);
    setChatMessages([]);
    setChatInputValue('');
    setChatContext(null);
    setIsChatThinking(false);
    chatAiRequestRef.current = null;
  }, []);

  const attachSelectionToChat = useCallback(() => {
    const selection = getActiveSelectionForChat();
    if (!selection) {
      addToast('Highlight text in the editor to attach it as context.', 'info');
      return;
    }
    setChatContext(selection);
    addToast('Attached selected text to this chat session.', 'info');
  }, [addToast, getActiveSelectionForChat]);

  const clearChatContext = useCallback(() => {
    setChatContext(null);
  }, []);

  const sendChatMessage = useCallback(() => {
    const prompt = chatInputValue.trim();
    if (!prompt) return;

    if (isAnyAiThinking) {
      addToast('AI is already running for this stream.', 'info');
      return;
    }

    const userMessageId = crypto.randomUUID();
    const assistantMessageId = crypto.randomUUID();
    const nextUserMessage: EditorChatMessage = {
      id: userMessageId,
      role: 'user',
      content: prompt,
      status: 'complete',
    };

    const priorTranscript = [...chatMessages, nextUserMessage]
      .filter((entry) => entry.content.trim().length > 0)
      .slice(-12)
      .map((entry) => `${entry.role === 'user' ? 'User' : 'Assistant'}: ${entry.content.trim()}`)
      .join('\n\n');

    const contextSections: string[] = [];
    if (chatContext?.text.trim()) {
      contextSections.push(`Selected stream text:\n\"\"\"\n${chatContext.text.trim()}\n\"\"\"`);
    }
    if (priorTranscript) {
      contextSections.push(`Conversation so far:\n${priorTranscript}`);
    }

    setChatInputValue('');
    setChatMessages((previous) => [
      ...previous,
      nextUserMessage,
      {
        id: assistantMessageId,
        role: 'assistant',
        content: '',
        status: 'streaming',
      },
    ]);
    setIsChatThinking(true);
    setIsChatOpen(true);
    setIsChatMinimized(false);

    const requestId = crypto.randomUUID();
    chatAiRequestRef.current = {
      id: requestId,
      buffer: '',
      assistantMessageId,
    };

    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: prompt,
        context: contextSections.length > 0 ? contextSections.join('\n\n') : undefined,
        imageURLs: chatContext?.imageUrls ?? [],
      },
    });
  }, [addToast, chatContext, chatInputValue, chatMessages, isAnyAiThinking, stream.id]);

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
        setShowInspector(false);
        closePrompt();
        if (isChatOpen && !isChatMinimized) {
          minimizeEditorChat();
          return;
        }
        hideSelectionMenu();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [
    closePrompt,
    handleOpenPrompt,
    handleSend,
    hideSelectionMenu,
    isChatMinimized,
    isChatOpen,
    isEditorActive,
    minimizeEditorChat,
  ]);

  useEffect(() => {
    return () => clearSelectionMenuTimer();
  }, [clearSelectionMenuTimer]);

  useEffect(() => {
    if (isChatOpen && !isChatMinimized) {
      hideSelectionMenu();
    }
  }, [hideSelectionMenu, isChatMinimized, isChatOpen]);

  useEffect(() => {
    const handleSelectionChange = () => {
      const selection = window.getSelection();
      if (!selection || selection.rangeCount === 0) {
        hideSelectionMenu();
        return;
      }
      scheduleSelectionMenu();
    };

    document.addEventListener('selectionchange', handleSelectionChange);
    return () => document.removeEventListener('selectionchange', handleSelectionChange);
  }, [hideSelectionMenu, scheduleSelectionMenu]);

  useEffect(() => {
    if (!isChatOpen || isChatMinimized) return;
    const messagesContainer = chatMessagesRef.current;
    if (!messagesContainer) return;
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
  }, [chatMessages, isChatMinimized, isChatOpen]);

  useEffect(() => {
    if (!floatingMenu.visible) return;

    const updatePlacement = () => {
      const selection = getSelectionContext(false);
      const placement = getFloatingMenuPlacement();
      if (!selection || !placement) {
        hideSelectionMenu();
        return;
      }
      setFloatingMenu((previous) => ({
        ...previous,
        visible: true,
        left: placement.left,
        top: placement.top,
      }));
    };

    window.addEventListener('resize', updatePlacement);
    window.addEventListener('scroll', updatePlacement, true);
    return () => {
      window.removeEventListener('resize', updatePlacement);
      window.removeEventListener('scroll', updatePlacement, true);
    };
  }, [floatingMenu.visible, getFloatingMenuPlacement, getSelectionContext, hideSelectionMenu]);

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

  useEffect(() => {
    if (!showPrompt) {
      scheduleSelectionMenu();
    } else {
      hideSelectionMenu();
    }
  }, [hideSelectionMenu, scheduleSelectionMenu, showPrompt]);

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

  const handleNavigateToCell = useCallback(() => {
    addToast('Cell anchors are not available in document editor mode yet.', 'info');
  }, [addToast]);

  const handleNavigateToSource = useCallback((sourceId: string) => {
    setHighlightedSourceId(sourceId);
    setShowInspector(true);
  }, []);

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
            disabled={isAnyAiThinking}
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
            disabled={isAnyAiThinking}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
              <path d="M4 3h16a1 1 0 011 1v11a1 1 0 01-1 1H8l-4 4v-4H4a1 1 0 01-1-1V4a1 1 0 011-1zm1 2v9h1v1.6L7.6 14H19V5H5zm3 2h8v1H8V7zm0 3h5v1H8v-1z" />
            </svg>
          </button>
        </div>
      )}

      {!isChatOpen && (
        <button
          type="button"
          className="editor-chat-launcher"
          onClick={openEditorChat}
          title="Open editor chat"
          aria-label="Open editor chat"
        >
          <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
            <path d="M12 2a4 4 0 0 0-4 4v1.2A5.8 5.8 0 0 0 4.2 13v.2c0 2.8 2.2 5 5 5h.8l1.2 1.8c.3.5 1 .5 1.4 0l1.2-1.8h.8c2.8 0 5-2.2 5-5V13A5.8 5.8 0 0 0 16 7.2V6a4 4 0 0 0-4-4zm-2 4a2 2 0 1 1 4 0v1h-4V6zm-2.8 7A2.8 2.8 0 0 1 10 10.2h4A2.8 2.8 0 0 1 16.8 13v.2A2.8 2.8 0 0 1 14 16h-1.4l-.6.9-.6-.9H10a2.8 2.8 0 0 1-2.8-2.8V13z" />
          </svg>
        </button>
      )}

      {isChatOpen && isChatMinimized && (
        <div className="editor-chat-tab">
          <button
            type="button"
            className="editor-chat-tab-open"
            onClick={restoreEditorChat}
          >
            Chat
          </button>
          <button
            type="button"
            className="editor-chat-tab-close"
            onClick={closeEditorChat}
            aria-label="Close chat"
            title="Close chat"
          >
            ×
          </button>
        </div>
      )}

      {isChatOpen && !isChatMinimized && (
        <div className="editor-chat-overlay">
          <section className="editor-chat-panel" aria-label="Editor chat">
            <header className="editor-chat-header">
              <div className="editor-chat-title-wrap">
                <h2>Chat</h2>
                <span className="editor-chat-status">
                  {isChatThinking ? 'Thinking…' : 'Ready'}
                </span>
              </div>
              <div className="editor-chat-controls">
                <button type="button" onClick={attachSelectionToChat}>
                  Attach Selection
                </button>
                <button type="button" onClick={minimizeEditorChat}>
                  Minimize
                </button>
                <button type="button" onClick={closeEditorChat}>
                  Close
                </button>
              </div>
            </header>

            {chatContext && (
              <div className="editor-chat-context">
                <span>
                  Context: {chatContext.text.trim().replace(/\s+/g, ' ').slice(0, 220)}
                  {chatContext.text.trim().length > 220 ? '…' : ''}
                </span>
                <button type="button" onClick={clearChatContext} aria-label="Clear context">
                  Clear
                </button>
              </div>
            )}

            <div className="editor-chat-messages" ref={chatMessagesRef}>
              {chatMessages.length === 0 && (
                <div className="editor-chat-empty">
                  Ask about highlighted text, or start a general conversation.
                </div>
              )}

              {chatMessages.map((message) => (
                <div
                  key={message.id}
                  className={`editor-chat-message editor-chat-message--${message.role}`}
                >
                  <div className="editor-chat-bubble">
                    <div className="editor-chat-message-meta">
                      <span>{message.role === 'assistant' ? 'Assistant' : 'You'}</span>
                      {message.modelId && <span>{message.modelId}</span>}
                    </div>
                    <p>
                      {message.content || (message.status === 'streaming' ? 'Thinking…' : '')}
                    </p>
                  </div>
                  {message.role === 'assistant' && (
                    <button
                      type="button"
                      className="editor-chat-insert"
                      title="Insert at cursor"
                      aria-label="Insert at cursor"
                      onClick={() => insertTextAtCursor(message.content)}
                      disabled={!message.content.trim() || message.status === 'streaming'}
                    >
                      +
                    </button>
                  )}
                </div>
              ))}
            </div>

            <form
              className="editor-chat-composer"
              onSubmit={(event) => {
                event.preventDefault();
                sendChatMessage();
              }}
            >
              <textarea
                value={chatInputValue}
                onChange={(event) => setChatInputValue(event.target.value)}
                placeholder="Ask about this stream..."
                rows={3}
                onKeyDown={(event) => {
                  if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
                    event.preventDefault();
                    sendChatMessage();
                  }
                }}
              />
              <button
                type="submit"
                disabled={!chatInputValue.trim() || isAnyAiThinking}
              >
                Send
              </button>
            </form>
          </section>
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
                markdown({ base: markdownLanguage, codeLanguages: languages }),
                syntaxHighlighting(markdownHighlightStyle),
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
      </div>

      {showInspector && (
        <div
          className="stream-inspector-overlay"
          onClick={() => setShowInspector(false)}
        >
          <div
            className="stream-inspector-drawer"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="stream-inspector-header">
              <h2>Sources</h2>
              <button
                type="button"
                className="stream-inspector-close"
                onClick={() => setShowInspector(false)}
                aria-label="Close sources"
              >
                Close
              </button>
            </div>
            <SidePanel
              cells={[]}
              focusedCellId={null}
              onCellClick={() => {}}
              streamId={stream.id}
              sources={sources}
              onSourceRemoved={handleSourceRemoved}
              highlightedSourceId={highlightedSourceId || pendingSourceId}
              onClearHighlight={() => {
                setHighlightedSourceId(null);
                onClearPendingSource?.();
              }}
            />
          </div>
        </div>
      )}

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
