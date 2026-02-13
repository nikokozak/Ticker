import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { EditorView } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { bridge, Stream, SourceReference } from '../types';
import { SidePanel } from './SidePanel';
import { SearchModal } from './SearchModal';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { useToastStore } from '../store/toastStore';

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

const markdownHighlightStyle = HighlightStyle.define([
  {
    tag: [t.heading, t.heading1, t.heading2, t.heading3, t.heading4, t.heading5, t.heading6],
    color: 'var(--color-text)',
    textDecoration: 'none',
    fontWeight: '620',
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

  const titleInputRef = useRef<HTMLInputElement>(null);
  const imageInputRef = useRef<HTMLInputElement>(null);
  const editorShellRef = useRef<HTMLDivElement>(null);
  const editorViewRef = useRef<any>(null);
  const lastSavedContentRef = useRef(stream.document?.markdown ?? '');

  const insertImageAtCursor = useCallback((imageUrl: string, altText = 'image') => {
    const safeAlt = altText.replace(/[\[\]\(\)]/g, '').trim() || 'image';
    const snippet = `\n![${safeAlt}](${imageUrl})\n`;
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

  useEffect(() => {
    setMarkdownContent(stream.document?.markdown ?? '');
    lastSavedContentRef.current = stream.document?.markdown ?? '';
    setTitle(stream.title);
    setSaveState('saved');
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
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setShowSearch(true);
        return;
      }
      if (e.key === 'Escape') {
        setShowInspector(false);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

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

  useEffect(() => {
    const handlePaste = (event: ClipboardEvent) => {
      const shell = editorShellRef.current;
      if (!shell) return;
      const active = document.activeElement;
      if (!active || !shell.contains(active)) return;
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
  }, [insertImageFiles]);

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
          onClick={() => imageInputRef.current?.click()}
          className="open-inspector-button"
          type="button"
          title="Insert image"
        >
          Image
        </button>
        <input
          ref={imageInputRef}
          type="file"
          accept="image/*"
          style={{ display: 'none' }}
          onChange={(event) => {
            const files = Array.from(event.target.files || []);
            if (files.length > 0) {
              void insertImageFiles(files);
            }
            event.currentTarget.value = '';
          }}
        />
        <button
          onClick={() => setShowInspector(true)}
          className="open-inspector-button"
          title="Open sources"
          type="button"
        >
          Sources
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
                markdown({ base: markdownLanguage, codeLanguages: languages }),
                syntaxHighlighting(markdownHighlightStyle),
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
