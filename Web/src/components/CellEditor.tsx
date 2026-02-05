import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Placeholder from '@tiptap/extension-placeholder';
import Mention from '@tiptap/extension-mention';
import Image from '@tiptap/extension-image';
import { useEffect, useRef, useMemo, useCallback } from 'react';
import { createReferenceSuggestion } from './ReferenceSuggestion';
import { useBlockStore } from '../store/blockStore';
import { Cell } from '../types/models';
import { bridge } from '../types';
import { extractFirstHeadingFromHtml } from '../utils/cellTitle';
import { debugError, debugLog, debugWarn } from '../utils/debug';
import { extractFirstHeadingFromHtml } from '../utils/cellTitle';

interface CellEditorProps {
  content: string;
  placeholder?: string;
  autoFocus?: boolean;
  cellId?: string; // Current cell's ID to exclude from suggestions
  streamId?: string; // Stream ID for saving images
  onChange: (content: string) => void;
  onEnter?: () => void;
  onThink?: () => void;
  onBackspaceEmpty?: () => void;
  onArrowUp?: () => void;
  onArrowDown?: () => void;
}

export function CellEditor({
  content,
  placeholder = 'Type something...',
  autoFocus = false,
  cellId,
  streamId,
  onChange,
  onEnter,
  onThink,
  onBackspaceEmpty,
  onArrowUp,
  onArrowDown,
}: CellEditorProps) {
  // Track if change originated from user typing (to avoid cursor reset)
  const isLocalChange = useRef(false);

  // Get cells for reference suggestions (exclude current cell and empty spacing cells)
  const getCells = useMemo(() => {
    return (): Cell[] => {
      const blocks = useBlockStore.getState().getBlocksArray();
      return blocks.filter((b) => {
        // Exclude current cell
        if (cellId && b.id === cellId) return false;
        // Always include AI responses (even if content appears empty after HTML strip)
        if (b.type === 'aiResponse') return true;
        // Always include cells with a blockName or a heading-derived title
        if (b.blockName || extractFirstHeadingFromHtml(b.content)) return true;
        // Exclude empty cells (spacing blocks)
        const textContent = b.content.replace(/<[^>]*>/g, '').trim();
        if (textContent.length === 0) return false;
        return true;
      });
    };
  }, [cellId]);

  // Create suggestion config with cell getter
  const suggestionConfig = useMemo(
    () => createReferenceSuggestion(getCells),
    [getCells]
  );

  // Handle image file drop/paste
  const handleImageFile = useCallback(async (file: File): Promise<string | null> => {
    if (!streamId) {
      debugWarn('Cannot save image: no streamId provided');
      return null;
    }

    // Read file as base64
    return new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => {
        const base64 = (reader.result as string).split(',')[1]; // Remove data:image/...;base64, prefix

        // Generate a unique request ID to match response
        const requestId = crypto.randomUUID();

        // Timeout to prevent listener leak if response never comes
        const timeout = setTimeout(() => {
          unsubscribe();
          debugError('Image save timed out');
          resolve(null);
        }, 10000);

        // Set up listener for save response - match by requestId
        const unsubscribe = bridge.onMessage((message) => {
          // Only handle responses for this specific request
          if (message.type === 'imageSaved' && message.payload?.requestId === requestId) {
            clearTimeout(timeout);
            unsubscribe();
            // Use custom URL scheme that WKWebView can access
            const assetUrl = message.payload.assetUrl as string;
            resolve(assetUrl);
          } else if (message.type === 'imageSaveError' && message.payload?.requestId === requestId) {
            clearTimeout(timeout);
            unsubscribe();
            debugError('Failed to save image');
            resolve(null);
          }
        });

        // Send save request with requestId for response matching
        bridge.send({
          type: 'saveImage',
          payload: {
            streamId,
            data: base64,
            requestId,
          },
        });
      };
      reader.onerror = () => {
        debugError('Failed to read image file');
        resolve(null);
      };
      reader.readAsDataURL(file);
    });
  }, [streamId]);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        heading: {
          levels: [1, 2, 3],
        },
      }),
      Placeholder.configure({
        placeholder,
      }),
      Mention.configure({
        HTMLAttributes: {
          class: 'cell-reference',
        },
        renderLabel({ node }) {
          // Always use shortId for the reference syntax to ensure regex compatibility
          // node.attrs.shortId is the 4-char hex prefix, set by ReferenceSuggestion
          return `@block-${node.attrs.shortId ?? node.attrs.id.substring(0, 4).toLowerCase()}`;
        },
        suggestion: suggestionConfig,
      }),
      Image.configure({
        inline: false,
        allowBase64: false,
        HTMLAttributes: {
          class: 'cell-image',
          draggable: 'false',
        },
      }).extend({
        // Allow gap cursor before/after images
        addKeyboardShortcuts() {
          return {
            // Enter after image creates new paragraph
            Enter: ({ editor }) => {
              const { state } = editor;
              const { selection } = state;
              const { $from } = selection;

              // Check if we're right after an image
              const nodeBefore = $from.nodeBefore;
              if (nodeBefore?.type.name === 'image') {
                // Insert a paragraph after the image
                return editor.chain().insertContentAt($from.pos, { type: 'paragraph' }).focus().run();
              }
              return false;
            },
          };
        },
      }),
    ],
    content,
    autofocus: autoFocus,
    editorProps: {
      attributes: {
        class: 'cell-editor-content',
      },
      // Handle image drops
      handleDrop: (view, event, _slice, moved) => {
        if (moved || !event.dataTransfer?.files?.length) {
          return false;
        }

        const files = Array.from(event.dataTransfer.files);
        const imageFiles = files.filter(file => file.type.startsWith('image/'));

        if (imageFiles.length === 0) {
          return false;
        }

        event.preventDefault();

        // Get drop position
        const coordinates = view.posAtCoords({ left: event.clientX, top: event.clientY });

        // Process images sequentially to avoid race conditions
        (async () => {
          for (const file of imageFiles) {
            const url = await handleImageFile(file);
            if (url && coordinates) {
              // Insert at end of document (position changes as we insert)
              const node = view.state.schema.nodes.image.create({ src: url });
              const pos = Math.min(coordinates.pos, view.state.doc.content.size);
              const transaction = view.state.tr.insert(pos, node);
              view.dispatch(transaction);
            }
          }
        })();

        return true;
      },
      // Handle image paste
      handlePaste: (view, event) => {
        const items = event.clipboardData?.items;
        if (!items) return false;

        const imageItems = Array.from(items).filter(item => item.type.startsWith('image/'));
        if (imageItems.length === 0) return false;

        event.preventDefault();

        // Process images sequentially to avoid race conditions
        (async () => {
          for (const item of imageItems) {
            const file = item.getAsFile();
            if (!file) continue;

            const url = await handleImageFile(file);
            if (url) {
              // Insert image at current cursor position
              const node = view.state.schema.nodes.image.create({ src: url });
              const transaction = view.state.tr.replaceSelectionWith(node);
              view.dispatch(transaction);
            }
          }
        })();

        return true;
      },
      handleKeyDown: (view, event) => {
        const { state } = view;
        const { selection } = state;
        const { empty, $anchor } = selection;

        // Cmd+Enter - think with AI
        if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
          if (onThink) {
            event.preventDefault();
            onThink();
            return true;
          }
        }

        // Enter at end of content - create new cell
        // For empty cells, always allow Enter. For non-empty, check if at end.
        if (event.key === 'Enter' && !event.shiftKey) {
          const isEmpty = state.doc.textContent.length === 0;
          const isAtEnd = $anchor.pos >= state.doc.content.size - 1;
          if ((isEmpty || isAtEnd) && onEnter) {
            event.preventDefault();
            onEnter();
            return true;
          }
        }

        // Backspace at start of empty cell - delete cell
        if (event.key === 'Backspace' && empty) {
          const isAtStart = $anchor.pos === 1;
          const isEmpty = state.doc.textContent.length === 0;
          if (isAtStart && isEmpty && onBackspaceEmpty) {
            event.preventDefault();
            onBackspaceEmpty();
            return true;
          }
        }

        // Arrow up at start - focus previous cell
        // For empty cells, always navigate. For non-empty, check if at start.
        if (event.key === 'ArrowUp' && empty) {
          const isEmpty = state.doc.textContent.length === 0;
          const isAtStart = $anchor.pos <= 1;
          if ((isEmpty || isAtStart) && onArrowUp) {
            event.preventDefault();
            onArrowUp();
            return true;
          }
        }

        // Arrow down at end - focus next cell
        // For empty cells, always navigate. For non-empty, check if at end.
        if (event.key === 'ArrowDown' && empty) {
          const isEmpty = state.doc.textContent.length === 0;
          const isAtEnd = $anchor.pos >= state.doc.content.size - 1;
          if ((isEmpty || isAtEnd) && onArrowDown) {
            event.preventDefault();
            onArrowDown();
            return true;
          }
        }

        return false;
      },
    },
    onUpdate: ({ editor }) => {
      isLocalChange.current = true;
      onChange(editor.getHTML());
    },
  });

  // Update content when prop changes (from external source, not user typing)
  useEffect(() => {
    if (editor && content !== editor.getHTML()) {
      if (isLocalChange.current) {
        // Change came from user typing, don't reset cursor
        isLocalChange.current = false;
      } else {
        // Change came from outside (e.g., streaming), update content
        // TipTap 2.x API: setContent(content, emitUpdate, parseOptions)
        editor.commands.setContent(content, false, { preserveWhitespace: 'full' });
      }
    }
  }, [content, editor]);

  // Focus editor when autoFocus becomes true (only on mount or when isNew)
  // Use a ref to track if we've already focused, to avoid re-focusing on every render
  const hasFocused = useRef(false);

  useEffect(() => {
    if (autoFocus && editor && !hasFocused.current) {
      editor.commands.focus('end');
      hasFocused.current = true;
    }
    // Reset when autoFocus becomes false (e.g., cell is no longer new)
    if (!autoFocus) {
      hasFocused.current = false;
    }
  }, [autoFocus, editor]);

  // Handle pending image insertion from store (e.g., from native drag-and-drop)
  const pendingImage = useBlockStore((state) => state.pendingImage);
  const clearPendingImage = useBlockStore((state) => state.clearPendingImage);

  useEffect(() => {
    if (pendingImage && pendingImage.cellId === cellId && editor) {
      debugLog('[CellEditor] Processing pending image', {
        cellId: pendingImage.cellId,
        isTickerAsset: typeof pendingImage.url === 'string' && pendingImage.url.startsWith('ticker-asset:'),
      });
      
      const node = editor.schema.nodes.image.create({ src: pendingImage.url });
      
      // Insert at current selection
      const transaction = editor.state.tr.replaceSelectionWith(node);
      editor.view.dispatch(transaction);
      
      clearPendingImage();
    }
  }, [pendingImage, cellId, editor, clearPendingImage]);

  return (
    <div className="cell-editor">
      <EditorContent editor={editor} />
    </div>
  );
}
