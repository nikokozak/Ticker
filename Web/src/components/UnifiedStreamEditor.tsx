import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import Mention from '@tiptap/extension-mention';
import Document from '@tiptap/extension-document';
import { useMemo, useEffect, useCallback, useRef, useState } from 'react';
import { Stream, Cell, bridge } from '../types';
import { CellBlock } from '../extensions/CellBlock';
import { CellClipboard } from '../extensions/CellClipboard';
import { CellKeymap, CellKeymapCallbacks } from '../extensions/CellKeymap';
import { SidePanel } from './SidePanel';
import { ReferencePreview } from './ReferencePreview';
import { createReferenceSuggestion } from './ReferenceSuggestion';
import { useBlockStore } from '../store/blockStore';
import { Editor } from '@tiptap/core';
import { DOMSerializer, DOMParser, Node as ProseMirrorNode } from '@tiptap/pm/model';
import { Selection, NodeSelection } from '@tiptap/pm/state';
import { stripHtml, extractImages, buildImageBlock, extractImageURLs } from '../utils/html';
import { useBridgeMessages, EditorAPI } from '../hooks/useBridgeMessages';
import { isCellNodeEmpty } from '../extensions/cellEmpty';
import { filterReferenceSuggestionCells } from '../utils/referenceSuggestionCells';
import { IS_DEV, debugLog, debugWarn } from '../utils/debug';

/** Save debounce delay in ms - matches Cell component */
const SAVE_DEBOUNCE_MS = 500;

/** Baseline entry for tracking what was last saved */
interface BaselineEntry {
  content: string;
  order: number;
}

interface UnifiedStreamEditorProps {
  stream: Stream;
  onBack: () => void;
  onDelete: () => void;
  onNavigateToStream?: (streamId: string, targetId: string, targetType?: 'cell' | 'source') => void;
  pendingCellId?: string | null;
  pendingSourceId?: string | null;
  onClearPendingCell?: () => void;
  onClearPendingSource?: () => void;
}

/**
 * Escape a string so it is safe to embed inside a double-quoted HTML attribute value.
 */
function escapeHtmlAttribute(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * Escape plain text for safe inclusion inside HTML.
 */
function escapeHtmlText(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * Convert a cell to an HTML string wrapped in a cellBlock element.
 */
function cellToHtml(cell: Cell): string {
  const attrs: string[] = [
    'data-cell-block',
    `data-cell-id="${cell.id}"`,
    `data-cell-type="${cell.type}"`,
  ];

  if (cell.modelId) attrs.push(`data-model-id="${escapeHtmlAttribute(cell.modelId)}"`);
  if (cell.originalPrompt) attrs.push(`data-original-prompt="${escapeHtmlAttribute(cell.originalPrompt)}"`);
  if (cell.sourceApp) attrs.push(`data-source-app="${escapeHtmlAttribute(cell.sourceApp)}"`);
  if (cell.blockName) attrs.push(`data-block-name="${escapeHtmlAttribute(cell.blockName)}"`);
  if (cell.processingConfig?.refreshTrigger === 'onStreamOpen') attrs.push('data-is-live="true"');
  if (cell.processingConfig?.refreshTrigger === 'onDependencyChange') attrs.push('data-has-dependencies="true"');

  let content = cell.content || '';
  if (!content.trim()) {
    content = '<p></p>';
  } else if (!content.trimStart().startsWith('<')) {
    content = `<p>${escapeHtmlText(content)}</p>`;
  }

  return `<div ${attrs.join(' ')}>${content}</div>`;
}

/**
 * Build HTML content from all cells.
 */
function buildHtmlFromCells(cells: Cell[]): string {
  const sortedCells = [...cells].sort((a, b) => a.order - b.order);

  if (sortedCells.length === 0) {
    // This path should never be reached - callers must provide at least one UUID-backed cell.
    // initialCells always includes a bootstrap cell for empty streams.
    debugWarn(
      '[buildHtmlFromCells] Called with empty cells array - this indicates a bug. Callers should provide a bootstrap cell.'
    );
    // Return empty string rather than a non-UUID placeholder that would break persistence.
    return '';
  }

  return sortedCells.map(cellToHtml).join('');
}

/**
 * Create a real (UUID-backed) initial cell for a brand-new empty stream.
 * This matches the legacy editor behavior: empty streams still start with one editable cell.
 */
function createBootstrapCell(streamId: string): Cell {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    streamId,
    content: '<p></p>',
    type: 'text',
    sourceBinding: null,
    order: 0,
    createdAt: now,
    updatedAt: now,
  };
}

/**
 * Extract cell data from a TipTap editor document.
 * Returns an array of partial Cell objects with id, type, content, and order.
 */
function extractCellsFromDoc(editor: Editor): Partial<Cell>[] {
  const cells: Partial<Cell>[] = [];
  const { doc, schema } = editor.state;
  const serializer = DOMSerializer.fromSchema(schema);

  doc.forEach((node, _offset, index) => {
    if (node.type.name === 'cellBlock') {
      // Serialize the cellBlock's content (not the cellBlock itself) to HTML
      const contentFragment = node.content;
      const domFragment = serializer.serializeFragment(contentFragment);

      // Convert DOM fragment to HTML string
      const tempDiv = document.createElement('div');
      tempDiv.appendChild(domFragment);
      const html = tempDiv.innerHTML;

      const id: string | null = node.attrs.id ?? null;
      if (!id) {
        if (IS_DEV) {
          debugWarn('[UnifiedStreamEditor] cellBlock missing attrs.id; skipping during extract');
        }
        return;
      }

      cells.push({
        id,
        type: node.attrs.type || 'text',
        content: html,
        order: index,
        modelId: node.attrs.modelId || undefined,
        originalPrompt: node.attrs.originalPrompt || undefined,
        sourceApp: node.attrs.sourceApp || undefined,
        blockName: node.attrs.blockName || undefined,
        processingConfig: node.attrs.isLive
          ? { refreshTrigger: 'onStreamOpen' }
          : node.attrs.hasDependencies
            ? { refreshTrigger: 'onDependencyChange' }
            : undefined,
      });
    }
  });

  return cells;
}

/**
 * Find a cellBlock by its ID in the document.
 * Returns the position and node, or null if not found.
 */
function findCellBlockById(doc: ProseMirrorNode, cellId: string): { pos: number; node: ProseMirrorNode } | null {
  let result: { pos: number; node: ProseMirrorNode } | null = null;
  doc.forEach((node, offset) => {
    if (node.type.name === 'cellBlock' && node.attrs.id === cellId) {
      result = { pos: offset, node };
    }
  });
  return result;
}

// Custom document that only allows cellBlocks at the top level
const CustomDocument = Document.extend({
  content: 'cellBlock+',
});

/**
 * Unified stream editor - single TipTap instance for the entire stream.
 * Enables true cross-cell text selection.
 *
 * Slice 01: Read-only render with CellBlock nodes
 * Slice 02: Editable with store sync
 * Slice 03: Persistence with debounced + diff-based saves
 *           - Baseline tracking prevents save storms on load
 *           - Guards against cross-stream writes via streamIdRef
 *           - Flushes pending saves on stream switch and unmount
 * Slice 04: Enter/Backspace/Arrow boundary handling
 *           - Enter at end of cell creates new cellBlock
 *           - Backspace in empty cell at boundary deletes it
 *           - Arrow keys navigate across cell boundaries
 *           - All operations use UUID-based cell identity
 */
export function UnifiedStreamEditor({
  stream,
  onBack,
  onDelete,
}: UnifiedStreamEditorProps) {
  // Subscribe to only the stable actions we need.
  // Avoid subscribing to the entire store state object: on every keystroke we call updateBlock,
  // which would otherwise re-render this component and (potentially) churn TipTap options.
  const loadStream = useBlockStore((s) => s.loadStream);
  const getBlock = useBlockStore((s) => s.getBlock);
  const updateBlock = useBlockStore((s) => s.updateBlock);
  const addBlock = useBlockStore((s) => s.addBlock);
  const deleteBlock = useBlockStore((s) => s.deleteBlock);
  const startStreaming = useBlockStore((s) => s.startStreaming);
  const setFocus = useBlockStore((s) => s.setFocus);
  const cellCount = useBlockStore((s) => s.blockOrder.length);
  const lastFocusedCellIdRef = useRef<string | null>(null);

  // Stream-level UI state (parity with StreamEditor)
  const [title, setTitle] = useState(stream.title);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showExportMenu, setShowExportMenu] = useState(false);
  const titleInputRef = useRef<HTMLInputElement>(null);

  // Track if we've initialized the store for this stream
  const initializedStreamId = useRef<string | null>(null);
  const bootstrapCellRef = useRef<Cell | null>(null);
  const bootstrapStreamIdRef = useRef<string | null>(null);

  // Persistence refs (Slice 03)
  // Baseline tracks what was last saved - used for diffing
  const baselineRef = useRef<Map<string, BaselineEntry>>(new Map());
  // Pending saves (cellId -> latest content/order seen from the editor doc)
  // This avoids relying on store-diffing to decide what to persist.
  const pendingSavesRef = useRef<Map<string, BaselineEntry>>(new Map());
  // Debounce timeout for batching saves
  const saveTimeoutRef = useRef<number | null>(null);
  // Guard against cross-stream writes (stream switch before save completes)
  const streamIdRef = useRef<string>(stream.id);

  // Build initial cells and HTML.
  // Empty streams still need a real UUID-backed cell so persistence works (Swift rejects non-UUID ids).
  const initialCells = useMemo(() => {
    if (stream.cells.length > 0) return stream.cells;

    if (bootstrapStreamIdRef.current !== stream.id) {
      bootstrapCellRef.current = createBootstrapCell(stream.id);
      bootstrapStreamIdRef.current = stream.id;
    }

    return bootstrapCellRef.current ? [bootstrapCellRef.current] : [];
  }, [stream.id, stream.cells]);

  const initialHtml = useMemo(() => buildHtmlFromCells(initialCells), [initialCells]);

  // Reference suggestion config (shared with legacy CellEditor/PromptEditor).
  // NOTE: Use store.getState() to avoid subscribing UnifiedStreamEditor to per-keystroke store churn.
  const getCellsForReferenceSuggestion = useMemo(() => {
    return (): Cell[] => {
      const store = useBlockStore.getState();
      const focusedId = store.focusedBlockId;
      const blocks = store.getBlocksArray();
      return filterReferenceSuggestionCells(blocks, focusedId);
    };
  }, []);

  const referenceSuggestionConfig = useMemo(
    () => createReferenceSuggestion(getCellsForReferenceSuggestion),
    [getCellsForReferenceSuggestion]
  );

  // Keep streamIdRef in sync
  useEffect(() => {
    streamIdRef.current = stream.id;
  }, [stream.id]);

  // Keep local title state in sync on stream switches
  useEffect(() => {
    setTitle(stream.title);
    setIsEditingTitle(false);
    setShowDeleteConfirm(false);
    setShowExportMenu(false);
  }, [stream.id, stream.title]);

  // Title editing handlers (same behavior as StreamEditor)
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

  // Export stream to file (fire-and-forget; NSSavePanel is modal)
  const handleExport = useCallback((format: 'markdown' | 'text') => {
    bridge.send({ type: 'exportStream', payload: { streamId: stream.id, format } });
    setShowExportMenu(false);
  }, [stream.id]);

  /**
   * Save pending edited cells (debounced).
   *
   * Why pending ref?
   * - TipTap is the true source-of-truth during editing.
   * - Store updates can be missed or normalized; pending tracks what the editor actually produced.
   * - Swift requires UUID ids; we always map doc index -> store.blockOrder UUID.
   */
  const savePendingCells = useCallback(() => {
    const currentStreamId = streamIdRef.current;

    // Safety check: don't save if stream ID doesn't match
    if (currentStreamId !== stream.id) {
      if (IS_DEV) {
        debugWarn('[UnifiedStreamEditor] savePendingCells: streamId mismatch, skipping save');
      }
      return;
    }

    const baseline = baselineRef.current;
    const pending = pendingSavesRef.current;
    const store = useBlockStore.getState();

    let savedCount = 0;

    if (IS_DEV && !window.webkit?.messageHandlers?.bridge) {
      debugWarn(
        '[UnifiedStreamEditor] window.webkit.messageHandlers.bridge missing; saveCell will be a no-op (running outside the macOS app?)'
      );
    }

    // Persist only the cells we saw edits for.
    // (We still baseline-diff as a second guard against save storms.)
    pending.forEach((pendingEntry, cellId) => {
      const cell = store.getBlock(cellId);
      if (!cell) return;

      const baselineEntry = baseline.get(cellId);
      const hasChanged =
        !baselineEntry ||
        baselineEntry.content !== pendingEntry.content ||
        baselineEntry.order !== pendingEntry.order;

      if (!hasChanged) {
        pending.delete(cellId);
        return;
      }

      bridge.send({
        type: 'saveCell',
        payload: {
          id: cellId,
          streamId: currentStreamId,
          content: pendingEntry.content,
          type: cell.type,
          order: pendingEntry.order,
          originalPrompt: cell.originalPrompt,
          modelId: cell.modelId,
          sourceApp: cell.sourceApp,
          references: cell.references,
          blockName: cell.blockName,
          processingConfig: cell.processingConfig,
          modifiers: cell.modifiers,
          sourceBinding: cell.sourceBinding,
        },
      });

      baseline.set(cellId, { content: pendingEntry.content, order: pendingEntry.order });
      pending.delete(cellId);
      savedCount++;
    });

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] savePendingCells', { savedCount, pendingRemaining: pending.size });
    }
  }, [stream.id]);

  /**
   * Schedule a debounced save.
   * Cancels any pending save and schedules a new one.
   */
  const scheduleSave = useCallback(() => {
    if (saveTimeoutRef.current !== null) {
      window.clearTimeout(saveTimeoutRef.current);
    }
    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] scheduleSave');
    }
    saveTimeoutRef.current = window.setTimeout(() => {
      saveTimeoutRef.current = null;
      if (IS_DEV) {
        debugLog('[UnifiedStreamEditor] scheduleSave: fired');
      }
      savePendingCells();
    }, SAVE_DEBOUNCE_MS);
  }, [savePendingCells]);

  /**
   * Flush any pending save immediately.
   * Called on blur, stream switch, or unmount.
   */
  const flushPendingSave = useCallback(() => {
    if (saveTimeoutRef.current !== null) {
      window.clearTimeout(saveTimeoutRef.current);
      saveTimeoutRef.current = null;
    }
    // Flush even if we didn't have a timeout; pending edits may still exist.
    savePendingCells();
  }, [savePendingCells]);

  /**
   * Create a new cell after the given cell.
   * Called by CellKeymap when Enter is pressed at the end of a cell.
   * Returns the new cell's UUID.
   */
  const handleCreateCell = useCallback((afterCellId: string): string => {
    const newId = crypto.randomUUID();
    const now = new Date().toISOString();

    // Get the order of the cell we're inserting after
    const afterBlock = getBlock(afterCellId);
    const newOrder = afterBlock ? afterBlock.order + 1 : 0;

    const newCell: Cell = {
      id: newId,
      streamId: stream.id,
      content: '<p></p>',
      type: 'text',
      sourceBinding: null,
      order: newOrder,
      createdAt: now,
      updatedAt: now,
    };

    // Add to store
    addBlock(newCell, afterCellId);

    // Use the store's post-insert order (blockStore may renormalize).
    const inserted = useBlockStore.getState().getBlock(newId);
    const insertedOrder = inserted?.order ?? newOrder;

    // Add to baseline (so it doesn't trigger a save until actually edited)
    baselineRef.current.set(newId, { content: newCell.content, order: insertedOrder });

    // Persist to Swift immediately (new cells should save right away)
    bridge.send({
      type: 'saveCell',
      payload: {
        id: newId,
        streamId: stream.id,
        content: newCell.content,
        type: newCell.type,
        order: insertedOrder,
      },
    });

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] Created new cell', { newId, afterCellId });
    }

    return newId;
  }, [stream.id, getBlock, addBlock]);

  /**
   * Delete an empty cell.
   * Called by CellKeymap when Backspace is pressed in an empty cell at the boundary.
   */
  const handleDeleteCell = useCallback((cellId: string) => {
    // Remove from store
    deleteBlock(cellId);

    // Remove from baseline and pending saves
    baselineRef.current.delete(cellId);
    pendingSavesRef.current.delete(cellId);

    // Persist deletion to Swift
    bridge.send({
      type: 'deleteCell',
      payload: { id: cellId },
    });

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] Deleted cell', { cellId });
    }
  }, [deleteBlock]);

  /**
   * Trigger AI thinking for a cell.
   * Called by CellKeymap when Cmd+Enter is pressed.
   */
  const handleThink = useCallback((cellId: string) => {
    const cell = getBlock(cellId);
    if (!cell) return;

    const originalPrompt = stripHtml(cell.content || '').trim();
    if (!originalPrompt) {
      if (IS_DEV) {
        debugLog('[UnifiedStreamEditor] handleThink: empty prompt, skipping');
      }
      return;
    }

    // Extract images from cell content - will be preserved visually
    const images = extractImages(cell.content);
    const imageBlock = buildImageBlock(images);
    const currentCellImageURLs = extractImageURLs(cell.content);

    // Get prior cells for context
    const store = useBlockStore.getState();
    const cells = store.getBlocksArray();
    const cellIndex = cells.findIndex(c => c.id === cellId);
    const priorCells = cellIndex > 0 ? cells.slice(0, cellIndex) : [];

    // Mark cell as streaming in store
    startStreaming(cellId, imageBlock);

    // Transform cell into AI response type
    updateBlock(cellId, {
      type: 'aiResponse',
      originalPrompt,
      content: imageBlock || '<p></p>',
    });

    // Persist the type transition immediately (matches legacy StreamEditor behavior).
    // This ensures we don't lose the prompt/type if the app quits mid-stream.
    bridge.send({
      type: 'saveCell',
      payload: {
        id: cellId,
        streamId: stream.id,
        content: imageBlock || '<p></p>',
        type: 'aiResponse',
        originalPrompt,
        order: cell.order,
        sourceApp: cell.sourceApp,
        references: cell.references,
      },
    });

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] handleThink: dispatching AI request for cell', { cellId });
    }

    // Dispatch think request to Swift (Swift only understands "think").
    bridge.send({
      type: 'think',
      payload: {
        cellId,
        streamId: stream.id,
        currentCell: originalPrompt,
        imageURLs: currentCellImageURLs,
        priorCells: priorCells.map(c => ({
          content: stripHtml(c.content),
          type: c.type,
          imageURLs: extractImageURLs(c.content),
        })),
      },
    });
  }, [stream.id, getBlock, updateBlock, startStreaming]);

  /**
   * CellKeymap callbacks for Enter/Backspace at cell boundaries.
   * Stable reference to avoid re-creating the extension on every render.
   */
  const cellKeymapCallbacks = useRef<CellKeymapCallbacks>({
    onCreateCell: (afterCellId: string) => handleCreateCell(afterCellId),
    onDeleteCell: (cellId: string) => handleDeleteCell(cellId),
    onThink: (cellId: string) => handleThink(cellId),
  });

  // Keep callbacks in sync
  useEffect(() => {
    // IMPORTANT: mutate existing object, don't replace it.
    // The extension captured the original object reference via configure();
    // replacing the object would leave the keymap calling stale callbacks.
    cellKeymapCallbacks.current.onCreateCell = handleCreateCell;
    cellKeymapCallbacks.current.onDeleteCell = handleDeleteCell;
    cellKeymapCallbacks.current.onThink = handleThink;
  }, [handleCreateCell, handleDeleteCell, handleThink]);

  // Handle editor updates - extract cells and sync to store, then schedule save
  const handleUpdate = useCallback(({ editor }: { editor: Editor }) => {
    const extractedCells = extractCellsFromDoc(editor);
    const isReordering = useBlockStore.getState().isReordering;

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] onUpdate: extracted cells', { count: extractedCells.length });
    }

    let hasChanges = false;

    // Detect structural deletions (e.g., multi-cell selection delete, merges at boundaries).
    // If a cellBlock id disappears from the doc, we must delete it from the store and persist deleteCell.
    // This is required to avoid "looks deleted until reload" bugs.
    const docCellIds = new Set<string>();
    for (const extracted of extractedCells) {
      if (extracted.id) docCellIds.add(extracted.id);
    }

    const { blockOrder } = useBlockStore.getState();
    for (const existingId of blockOrder) {
      if (!docCellIds.has(existingId)) {
        if (IS_DEV) {
          debugLog('[UnifiedStreamEditor] Doc removed cellBlock, persisting delete', { existingId });
        }
        handleDeleteCell(existingId);
      }
    }

    // Slice 04: Use cell ID from node attrs (UUID), not positional index.
    // This is critical for supporting cell creation/deletion/reorder.
    for (let i = 0; i < extractedCells.length; i++) {
      const extracted = extractedCells[i];
      const cellId = extracted.id;
      if (!cellId) continue;

      const existingBlock = getBlock(cellId);
      if (!existingBlock) {
        // Cell exists in doc but not in store.
        // Prefer to self-heal: treat doc as authoritative structure and create a minimal store block.
        if (IS_DEV) {
          debugLog('[UnifiedStreamEditor] Cell in doc but not in store; creating', { cellId });
        }
        const now = new Date().toISOString();
        const newCell: Cell = {
          id: cellId,
          streamId: stream.id,
          content: extracted.content ?? '<p></p>',
          type: (extracted.type as Cell['type']) ?? 'text',
          sourceBinding: null,
          order: extracted.order ?? 0,
          createdAt: now,
          updatedAt: now,
        };

        // Find the previous cell in doc order to insert after.
        // This keeps store order aligned with the document when cells appear via paste/self-heal.
        let afterId: string | undefined;
        for (let j = i - 1; j >= 0; j--) {
          const prevId = extractedCells[j].id;
          if (prevId) {
            afterId = prevId;
            break;
          }
        }

        if (afterId) {
          // Insert after the previous cell
          addBlock(newCell, afterId);
        } else {
          // No previous cell - this should be at the start of the doc.
          // Add first (store appends), then move to front to match doc order.
          addBlock(newCell);
          const store = useBlockStore.getState();
          const currentOrder = store.blockOrder;
          const cellIndex = currentOrder.indexOf(cellId);
          if (cellIndex > 0) {
            // Move to front by reordering
            store.reorderBlocks(cellIndex, 0);
          }
        }
        // IMPORTANT: don't seed baseline for doc-created cells.
        // If this cell came from a paste of multiple cellBlocks, we need to persist it
        // (Swift requires UUID ids, and this is a *new* cell in the stream).
        pendingSavesRef.current.set(cellId, { content: newCell.content, order: newCell.order });
        hasChanges = true;
        continue;
      }

      const nextContent = extracted.content ?? existingBlock.content;
      const nextOrder = extracted.order ?? existingBlock.order;

      // During drag-reorder we *do not* want to schedule per-cell save storms.
      // Swift persistence is handled via the dedicated `reorderBlocks` message.
      //
      // However, we DO want baseline.order to track doc order so the next real edit
      // doesn't look like an order change and trigger redundant saves.
      if (isReordering) {
        const baselineEntry = baselineRef.current.get(cellId);
        baselineRef.current.set(cellId, {
          content: baselineEntry?.content ?? nextContent,
          order: nextOrder,
        });

        // Keep store content in sync if it somehow changed (shouldn't during reorder).
        if (existingBlock.content !== nextContent) {
          pendingSavesRef.current.set(cellId, { content: nextContent, order: nextOrder });
          hasChanges = true;
          updateBlock(cellId, { content: nextContent });
        }
        continue;
      }

      // Track pending edits against baseline (not store) so we don't miss scheduling saves.
      const baselineEntry = baselineRef.current.get(cellId);
      if (!baselineEntry || baselineEntry.content !== nextContent || baselineEntry.order !== nextOrder) {
        pendingSavesRef.current.set(cellId, { content: nextContent, order: nextOrder });
        hasChanges = true;
      }

      // CRITICAL: Don't update unchanged blocks.
      // updateBlock() bumps updatedAt and triggers store subscribers.
      if (existingBlock.content !== nextContent || existingBlock.order !== nextOrder) {
        updateBlock(cellId, {
          content: nextContent,
          order: nextOrder,
        });
      }
    }

    // Slice 3: Auto-reset empty AI cells to text type.
    // When an aiResponse cell becomes empty (all content deleted by user),
    // reset it to a normal text cell. This removes the AI chrome and allows
    // the user to start fresh.
    const storeState = useBlockStore.getState();
    for (const extracted of extractedCells) {
      const cellId = extracted.id;
      if (!cellId) continue;

      const storeCell = storeState.getBlock(cellId);
      if (!storeCell || storeCell.type !== 'aiResponse') continue;

      // Don't reset while streaming or refreshing
      if (storeState.isStreaming(cellId) || storeState.isRefreshing(cellId)) continue;

      // Find the cellBlock node in the document
      const cellInfo = findCellBlockById(editor.state.doc, cellId);
      if (!cellInfo) continue;

      // Check if the cell is empty
      if (!isCellNodeEmpty(cellInfo.node)) continue;

      debugLog('[UnifiedStreamEditor] Auto-resetting empty AI cell to text', { cellId });

      // Reset to text type in store
      updateBlock(cellId, {
        type: 'text',
        originalPrompt: undefined,
        modelId: undefined,
      });

      // Persist the reset
      bridge.send({
        type: 'saveCell',
        payload: {
          id: cellId,
          streamId: stream.id,
          content: storeCell.content || '<p></p>',
          type: 'text',
          order: storeCell.order,
          // Clear AI-specific fields
          originalPrompt: undefined,
          modelId: undefined,
          // Preserve other fields
          sourceApp: storeCell.sourceApp,
          blockName: storeCell.blockName,
          processingConfig: storeCell.processingConfig,
        },
      });

      // Update baseline to prevent re-saving
      baselineRef.current.set(cellId, {
        content: storeCell.content || '<p></p>',
        order: storeCell.order,
      });
    }

    // Schedule debounced save if there were changes (Slice 03)
    if (hasChanges) {
      scheduleSave();
    }
  }, [getBlock, updateBlock, scheduleSave, stream.id]);

  // Create the unified editor
  const editor = useEditor({
    extensions: [
      CustomDocument,
      StarterKit.configure({
        document: false,
        heading: {
          levels: [1, 2, 3],
        },
      }),
      // Must run before CellBlock parse/insert logic so pasted cellBlocks get fresh UUIDs.
      CellClipboard,
      CellBlock,
      CellKeymap.configure({
        callbacks: cellKeymapCallbacks.current,
      }),
      Image.configure({
        inline: false,
        allowBase64: false,
        HTMLAttributes: {
          class: 'cell-image',
          draggable: 'false',
        },
      }),
      Mention.configure({
        HTMLAttributes: {
          class: 'cell-reference',
        },
        renderLabel({ node }) {
          return `@block-${node.attrs.shortId ?? node.attrs.id?.substring(0, 4).toLowerCase() ?? '????'}`;
        },
        suggestion: referenceSuggestionConfig,
      }),
    ],
    content: initialHtml,
    editable: true, // Slice 02: Enable editing
    editorProps: {
      attributes: {
        class: 'unified-editor-content',
      },
      // Save immediately when focus leaves the editor (mirrors legacy Cell blur behavior).
      // This makes persistence feel responsive even with debouncing enabled.
      handleDOMEvents: {
        blur: () => {
          flushPendingSave();
          return false;
        },
      },
    },
    onUpdate: handleUpdate,
    onSelectionUpdate: ({ editor }) => {
      const { $from } = editor.state.selection;
      let focusedId: string | null = null;
      for (let depth = $from.depth; depth >= 0; depth--) {
        const node = $from.node(depth);
        if (node.type.name === 'cellBlock') {
          focusedId = node.attrs.id ?? null;
          break;
        }
      }
      if (focusedId !== lastFocusedCellIdRef.current) {
        lastFocusedCellIdRef.current = focusedId;
        setFocus(focusedId);
      }
    },
  });

  /**
   * Scroll and focus a target cell by ID.
   * Used by side panel navigation and @reference click/hover UX.
   */
  const scrollToCell = useCallback((cellId: string) => {
    if (!editor) return;

    const result = findCellBlockById(editor.state.doc, cellId);
    if (!result) return;

    // Scroll + place selection at the start of the cell content.
    const cellContentStart = result.pos + 1;
    const sel = Selection.findFrom(editor.state.doc.resolve(cellContentStart), 1, true);
    if (!sel) return;
    editor.view.dispatch(editor.state.tr.setSelection(sel).scrollIntoView());
    editor.view.focus();

    // Highlight the navigated-to cell wrapper (reuse legacy highlight CSS).
    const el = document.querySelector(`[data-cell-id="${cellId}"]`);
    if (!el) return;
    el.classList.add('block-wrapper--highlighted');
    window.setTimeout(() => {
      el.classList.remove('block-wrapper--highlighted');
    }, 2000);
  }, [editor]);

  /**
   * Handle clicks on inline cell references (TipTap mention spans).
   * Mirrors legacy behavior from Cell.tsx.
   */
  const handleReferenceClick = useCallback((e: React.MouseEvent) => {
    // Only handle plain left-clicks; let modified clicks behave normally.
    const isPlainPrimaryClick =
      e.button === 0 &&
      !e.metaKey &&
      !e.ctrlKey &&
      !e.altKey &&
      !e.shiftKey;
    if (!isPlainPrimaryClick) return;

    const target = e.target as HTMLElement;
    if (!target) return;

    // PromptEditor has its own editing semantics; don't hijack mention clicks there.
    if (target.closest('.prompt-editor-content')) return;

    // Check if clicked on a cell-reference element (TipTap mention).
    if (!(target.classList.contains('cell-reference') || target.closest('.cell-reference'))) {
      return;
    }

    e.preventDefault();
    e.stopPropagation();

    const refElement = target.classList.contains('cell-reference')
      ? target
      : target.closest('.cell-reference');
    if (!refElement) return;

    // TipTap mention stores identifier in data-id attribute.
    const refId = refElement.getAttribute('data-id');
    if (!refId) return;

    const referencedCell = useBlockStore.getState().getBlockByRef(refId);
    if (!referencedCell) return;

    scrollToCell(referencedCell.id);
  }, [scrollToCell]);

  /**
   * Replace the HTML content of a cell in the TipTap document.
   * Used by useBridgeMessages when AI completes or content needs to be updated.
   */
  const replaceCellHtml = useCallback((cellId: string, html: string) => {
    if (!editor) {
      if (IS_DEV) {
        debugWarn('[UnifiedStreamEditor] replaceCellHtml: editor not ready');
      }
      return;
    }

    const { doc, schema } = editor.state;

    // Find the cellBlock with this ID
    const result = findCellBlockById(doc, cellId);
    if (!result) {
      if (IS_DEV) {
        debugWarn('[UnifiedStreamEditor] replaceCellHtml: cell not found', { cellId });
      }
      return;
    }

    const { pos, node } = result;

    // Parse the new HTML as *cell content*, not as a whole document.
    //
    // IMPORTANT:
    // Our doc schema is `doc -> cellBlock+`. If we parse arbitrary HTML as a `doc`,
    // ProseMirror will "helpfully" wrap it in a `cellBlock` to satisfy the schema.
    // If we then insert that into an existing cellBlock, you get a *nested cellBlock*
    // (exactly the bug you saw: AI response appears as a cell-within-a-cell).
    const safeHtml = html && html.trim().length > 0 ? html : '<p></p>';
    const wrapper = document.createElement('div');
    wrapper.innerHTML = `<div data-cell-block data-cell-id="__parse" data-cell-type="text">${safeHtml}</div>`;

    const pmParser = DOMParser.fromSchema(schema);
    const parsedDoc = pmParser.parse(wrapper);
    const parsedCell = parsedDoc.firstChild;
    const parsedContent = parsedCell?.type.name === 'cellBlock' ? parsedCell.content : parsedDoc.content;

    // Replace the cellBlock content (keep the cellBlock node, replace its content)
    const cellStart = pos + 1;
    const cellEnd = pos + node.nodeSize - 1;

    const tr = editor.state.tr.replaceWith(cellStart, cellEnd, parsedContent);
    editor.view.dispatch(tr);

    // Prevent redundant "save storm" after AI completes.
    // useBridgeMessages already persisted the final content; by updating baseline here,
    // we avoid unified persistence re-saving the same content again.
    // IMPORTANT: Use safeHtml (normalized) to avoid "empty vs <p></p>" baseline mismatches.
    const order = useBlockStore.getState().getBlock(cellId)?.order ?? 0;
    baselineRef.current.set(cellId, { content: safeHtml, order });
    pendingSavesRef.current.delete(cellId);

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] replaceCellHtml: updated cell', { cellId });
    }
  }, [editor]);

  /**
   * Insert new cells into the TipTap document.
   * Used by useBridgeMessages when Quick Panel adds cells.
   * Cells are inserted at the end of the document.
   */
  const insertCells = useCallback((cells: Cell[]) => {
    if (!editor) {
      if (IS_DEV) {
        debugWarn('[UnifiedStreamEditor] insertCells: editor not ready');
      }
      return;
    }

    if (cells.length === 0) return;

    const { schema } = editor.state;

    // Build HTML for all cells and parse as a fragment
    const cellsHtml = cells.map(cell => cellToHtml(cell)).join('');
    const wrapper = document.createElement('div');
    wrapper.innerHTML = cellsHtml;

    const pmParser = DOMParser.fromSchema(schema);
    const parsedDoc = pmParser.parse(wrapper);

    // Insert at the end of the document
    const docEnd = editor.state.doc.content.size;
    const tr = editor.state.tr.insert(docEnd, parsedDoc.content);
    editor.view.dispatch(tr);

    // Add cells to store and baseline (they're already persisted by Swift)
    for (const cell of cells) {
      const normalizedContent = cell.content && cell.content.trim().length > 0 ? cell.content : '<p></p>';

      const existing = useBlockStore.getState().getBlock(cell.id);
      if (!existing) {
        addBlock({
          id: cell.id,
          streamId: cell.streamId,
          content: normalizedContent,
          type: cell.type,
          order: cell.order,
          sourceBinding: cell.sourceBinding || null,
          originalPrompt: cell.originalPrompt,
          modelId: cell.modelId,
          references: cell.references,
          sourceApp: cell.sourceApp,
          blockName: cell.blockName,
          processingConfig: cell.processingConfig,
          modifiers: cell.modifiers,
          createdAt: cell.createdAt || new Date().toISOString(),
          updatedAt: cell.updatedAt || new Date().toISOString(),
        });
      } else {
        // If handleUpdate self-healed this cell first, enrich it with full metadata
        // without inserting a duplicate ID into blockOrder.
        updateBlock(cell.id, {
          content: normalizedContent,
          type: cell.type,
          sourceBinding: cell.sourceBinding || null,
          originalPrompt: cell.originalPrompt,
          modelId: cell.modelId,
          references: cell.references,
          sourceApp: cell.sourceApp,
          blockName: cell.blockName,
          processingConfig: cell.processingConfig,
          modifiers: cell.modifiers,
        });
      }

      // Add to baseline so we don't trigger redundant saves.
      // IMPORTANT: use the store's post-insert order (blockStore renormalizes orders),
      // otherwise we can accidentally schedule saves due to order mismatches.
      const inserted = useBlockStore.getState().getBlock(cell.id);
      baselineRef.current.set(cell.id, {
        content: normalizedContent,
        order: inserted?.order ?? cell.order,
      });
      pendingSavesRef.current.delete(cell.id);
    }

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] insertCells: inserted cells', { count: cells.length });
    }
  }, [editor, addBlock, updateBlock]);

  /**
   * Insert an image at the current cursor position.
   * Used by useBridgeMessages when an image is dropped.
   */
  const insertImage = useCallback((imageUrl: string) => {
    if (!editor) {
      if (IS_DEV) {
        debugWarn('[UnifiedStreamEditor] insertImage: editor not ready');
      }
      return;
    }

    // If an image node is currently selected, NEVER replace it.
    // Instead, create a new cell below and insert the image there.
    const selection = editor.state.selection;
    if (selection instanceof NodeSelection && selection.node.type.name === 'image') {
      const { $from } = selection;

      // Find the enclosing cellBlock
      let cellBlockPos: number | null = null;
      let cellBlockNode: ProseMirrorNode | null = null;
      for (let depth = $from.depth; depth >= 0; depth--) {
        const n = $from.node(depth);
        if (n.type.name === 'cellBlock') {
          cellBlockPos = $from.before(depth);
          cellBlockNode = n;
          break;
        }
      }

      const afterCellId: string | null = cellBlockNode?.attrs?.id ?? null;
      if (!cellBlockNode || cellBlockPos === null || !afterCellId) {
        // Fallback: no cell context, just insert at cursor.
        editor.chain().focus().setImage({ src: imageUrl }).run();
        return;
      }

      // Create a new cell in store (and persist an initial empty cell row like Enter does).
      const newCellId = handleCreateCell(afterCellId);

      // Insert a new cellBlock node after the current one, with the image and an empty paragraph.
      const { schema } = editor.state;
      const cellBlockType = schema.nodes.cellBlock;
      const imageType = schema.nodes.image;
      const paragraphType = schema.nodes.paragraph;
      if (!cellBlockType || !imageType || !paragraphType) return;

      const imageNode = imageType.create({ src: imageUrl });
      const paragraphNode = paragraphType.create();
      const newCellNode = cellBlockType.create({ id: newCellId, type: 'text' }, [imageNode, paragraphNode]);

      const insertPos = cellBlockPos + cellBlockNode.nodeSize;
      const tr = editor.state.tr.insert(insertPos, newCellNode);

      // Place cursor into the paragraph after the image.
      const newCellContentStart = insertPos + 1;
      const sel = Selection.findFrom(tr.doc.resolve(newCellContentStart), 1, true);
      if (sel) tr.setSelection(sel);

      editor.view.dispatch(tr);
      editor.view.focus();
      return;
    }

    // Default: insert image at cursor position.
    editor.chain().focus().setImage({ src: imageUrl }).run();

    if (IS_DEV) {
      debugLog('[UnifiedStreamEditor] insertImage: inserted image', {
        isTickerAsset: typeof imageUrl === 'string' && imageUrl.startsWith('ticker-asset:'),
      });
    }
  }, [editor]);

  /**
   * EditorAPI for useBridgeMessages to update the TipTap document.
   */
  const editorAPI = useMemo<EditorAPI>(() => ({
    replaceCellHtml,
    insertCells,
    insertImage,
  }), [replaceCellHtml, insertCells, insertImage]);

  // Bridge message handling (AI streaming, modifiers, sources, etc.)
  const { sources, setSources } = useBridgeMessages({
    streamId: stream.id,
    initialSources: stream.sources,
    editorAPI,
  });

  const handleSourceRemoved = useCallback((sourceId: string) => {
    setSources(prev => prev.filter(s => s.id !== sourceId));
  }, [setSources]);

  const handleCellClickFromOutline = useCallback((cellId: string) => {
    scrollToCell(cellId);
  }, [scrollToCell]);

  // Initialize store with stream data on mount and seed baseline
  useEffect(() => {
    if (stream.id !== initializedStreamId.current) {
      // Flush any pending saves from previous stream before switching
      flushPendingSave();

      if (IS_DEV) {
        debugLog('[UnifiedStreamEditor] Initializing store for stream', { streamId: stream.id });
      }

      // Load stream data into store (bootstrap empty streams with 1 real cell)
      loadStream(stream.id, initialCells);
      initializedStreamId.current = stream.id;

      // Seed baseline from initial cells to prevent "save storm" on load
      // This ensures we only save cells that actually change after loading
      const baseline = baselineRef.current;
      baseline.clear();
      for (const cell of initialCells) {
        baseline.set(cell.id, { content: cell.content, order: cell.order });
      }

      if (IS_DEV) {
        debugLog('[UnifiedStreamEditor] Seeded baseline', { count: baseline.size });
      }
    }
  }, [stream.id, initialCells, loadStream, flushPendingSave]);

  // Cleanup: flush pending saves on unmount
  useEffect(() => {
    return () => {
      if (saveTimeoutRef.current !== null) {
        window.clearTimeout(saveTimeoutRef.current);
        saveTimeoutRef.current = null;
      }
      // Always attempt a final flush (pending saves are ref-based).
      flushPendingSave();
    };
  }, [flushPendingSave]);

  return (
    <div className="stream-editor">
      <header className="stream-header">
        <button onClick={onBack} className="back-button">
          &larr; Back
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
        <div className="export-menu-container">
          <button
            onClick={() => setShowExportMenu(!showExportMenu)}
            className="export-stream-button"
            title="Export stream"
            type="button"
          >
            Export
          </button>
          {showExportMenu && (
            <div className="export-menu-dropdown">
              <button
                onClick={() => handleExport('markdown')}
                className="export-menu-item"
                type="button"
              >
                Text (.md)
              </button>
              <button
                onClick={() => handleExport('text')}
                className="export-menu-item"
                type="button"
              >
                Text (.txt)
              </button>
            </div>
          )}
        </div>
        <button
          onClick={() => setShowDeleteConfirm(true)}
          className="delete-stream-button"
          title="Delete stream"
          type="button"
        >
          Delete
        </button>
      </header>

      {/* Delete confirmation dialog (parity with StreamEditor) */}
      {showDeleteConfirm && (
        <div className="delete-confirm-overlay" onClick={() => setShowDeleteConfirm(false)}>
          <div className="delete-confirm-dialog" onClick={(e) => e.stopPropagation()}>
            <h2>Delete this stream?</h2>
            <p>This will permanently delete "{title}" and all its contents. This cannot be undone.</p>
            <div className="delete-confirm-actions">
              <button
                className="delete-confirm-cancel"
                onClick={() => setShowDeleteConfirm(false)}
                type="button"
              >
                Cancel
              </button>
              <button
                className="delete-confirm-delete"
                onClick={() => {
                  setShowDeleteConfirm(false);
                  onDelete();
                }}
                type="button"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      <div className="stream-body">
        <div className="stream-content unified-editor-container" onClick={handleReferenceClick}>
          {editor ? (
            <EditorContent editor={editor} />
          ) : (
            <div className="loading-state">Loading editor...</div>
          )}

          {IS_DEV ? (
            <div
              style={{
                marginTop: '20px',
                padding: '10px',
                background: 'var(--color-surface)',
                borderRadius: '4px',
                fontSize: '12px',
                color: 'var(--color-text-secondary)',
              }}
            >
              <strong>Debug:</strong> {stream.cells.length} cells from stream, {cellCount} in store.
              Persistence enabled (debounced 500ms, diff-based saves).
            </div>
          ) : null}
        </div>

        <UnifiedStreamSidePanel
          streamId={stream.id}
          sources={sources}
          onSourceRemoved={handleSourceRemoved}
          onCellClick={handleCellClickFromOutline}
        />
      </div>

      {/* Global reference preview tooltip */}
      <ReferencePreview onScrollToCell={scrollToCell} />
    </div>
  );
}

function UnifiedStreamSidePanel({
  streamId,
  sources,
  onSourceRemoved,
  onCellClick,
}: {
  streamId: string;
  sources: import('../types').SourceReference[];
  onSourceRemoved: (sourceId: string) => void;
  onCellClick: (cellId: string) => void;
}) {
  // IMPORTANT:
  // Don't select `getBlocksArray()` directly here. It returns a *new array* each call.
  // With `useSyncExternalStore`, an unstable snapshot can cause infinite render loops
  // (React "maximum update depth exceeded").
  const blockOrder = useBlockStore((s) => s.blockOrder);
  const blocks = useBlockStore((s) => s.blocks);
  const focusedCellId = useBlockStore((s) => s.focusedBlockId);

  const cells = useMemo(() => {
    return blockOrder.map((id) => blocks.get(id)).filter(Boolean) as import('../types').Cell[];
  }, [blockOrder, blocks]);

  return (
    <SidePanel
      cells={cells}
      focusedCellId={focusedCellId}
      onCellClick={onCellClick}
      streamId={streamId}
      sources={sources}
      onSourceRemoved={onSourceRemoved}
    />
  );
}
