import { NodeViewWrapper, NodeViewContent } from '@tiptap/react';
import { NodeViewProps } from '@tiptap/core';
import { Node as ProseMirrorNode } from '@tiptap/pm/model';
import { useState, useCallback, useEffect, type MouseEvent as ReactMouseEvent } from 'react';
import { useBlockStore } from '../store/blockStore';
import { bridge } from '../types';
import { CellOverlay } from '../components/CellOverlay';
import { buildImageBlock, extractImageURLs, extractImages, stripHtml } from '../utils/html';
import { INTERNAL_CELL_DRAG_MIME, INTERNAL_CELL_DRAG_TEXT } from '../utils/cellDrag';
import { IS_DEV, debugLog, debugWarn } from '../utils/debug';

// Global drag state to coordinate between CellBlockViews
let globalDraggedCellId: string | null = null;
let lastReorderTime = 0;
let persistReorderTimeout: number | null = null;
let idleCleanupTimeout: number | null = null;
let autoscrollRAF: number | null = null;
let lastPointerY = 0;
const DRAG_CLEANUP_EVENT = 'ticker:cell-drag-cleanup';

// 1x1 transparent gif (prevents the browser drag image from "snapping back" visually)
const TRANSPARENT_DRAG_IMG_SRC =
  'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
const transparentDragImage = (() => {
  const img = new Image();
  img.src = TRANSPARENT_DRAG_IMG_SRC;
  return img;
})();

function persistReorderToSwift() {
  const store = useBlockStore.getState();
  const { streamId, blockOrder } = store;
  if (!streamId) {
    debugWarn('[CellBlockView] reorderBlocks: missing streamId in store; skipping persist');
    return;
  }

  const orders = blockOrder.map((id, order) => ({ id, order }));
  if (IS_DEV) {
    debugLog('[CellBlockView] Persist reorderBlocks', {
      streamId,
      count: orders.length,
      head: orders.slice(0, 3),
    });
  }
  bridge.send({
    type: 'reorderBlocks',
    payload: { streamId, orders },
  });
}

function schedulePersistReorder() {
  if (persistReorderTimeout !== null) {
    window.clearTimeout(persistReorderTimeout);
  }
  // Debounce: we only persist after the user pauses dragging.
  persistReorderTimeout = window.setTimeout(() => {
    persistReorderTimeout = null;
    if (globalDraggedCellId) persistReorderToSwift();
  }, 250);
}

function scheduleIdleCleanup() {
  if (idleCleanupTimeout !== null) {
    window.clearTimeout(idleCleanupTimeout);
  }
  // If dragend/drop never fires (NodeView churn), clean up anyway.
  idleCleanupTimeout = window.setTimeout(() => {
    idleCleanupTimeout = null;
    if (globalDraggedCellId) {
      // Ensure we persist once more before clearing.
      persistReorderToSwift();
    }
    cleanupDragState();
  }, 1000);
}

/** Start autoscroll loop that scrolls viewport when pointer is near edges. */
function startAutoscroll() {
  if (autoscrollRAF !== null) return;

  const EDGE_THRESHOLD = 80; // px from edge to start scrolling
  const SCROLL_SPEED = 8; // px per frame

  function tick() {
    const viewportHeight = window.innerHeight;
    if (lastPointerY < EDGE_THRESHOLD) {
      // Near top - scroll up
      window.scrollBy(0, -SCROLL_SPEED);
    } else if (lastPointerY > viewportHeight - EDGE_THRESHOLD) {
      // Near bottom - scroll down
      window.scrollBy(0, SCROLL_SPEED);
    }
    autoscrollRAF = requestAnimationFrame(tick);
  }

  autoscrollRAF = requestAnimationFrame(tick);
}

/** Stop autoscroll loop. */
function stopAutoscroll() {
  if (autoscrollRAF !== null) {
    cancelAnimationFrame(autoscrollRAF);
    autoscrollRAF = null;
  }
}

/** Clean up all drag-related state. */
function cleanupDragState() {
  document.body.classList.remove('is-cell-dragging');
  useBlockStore.getState().setIsReordering(false);
  globalDraggedCellId = null;
  stopAutoscroll();
  // NodeViews can be unmounted/re-rendered during live reorder. Drag terminal events are not reliable.
  // Broadcast a cleanup signal so any mounted CellBlockView can clear its local UI flags.
  window.dispatchEvent(new Event(DRAG_CLEANUP_EVENT));
}

/**
 * Find a cellBlock node by its ID in the document.
 * Returns the position and node, or null if not found.
 */
function findCellBlockById(doc: ProseMirrorNode, cellId: string | null): { pos: number; node: ProseMirrorNode } | null {
  if (!cellId) return null;
  let result: { pos: number; node: ProseMirrorNode } | null = null;
  doc.forEach((node, offset) => {
    if (node.type.name === 'cellBlock' && node.attrs.id === cellId) {
      result = { pos: offset, node };
    }
  });
  return result;
}

// Spinner SVG component for streaming/refreshing states
function Spinner() {
  return (
    <svg
      className="cell-block-spinner"
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M21 12a9 9 0 1 1-6.219-8.56" />
    </svg>
  );
}

// Static pseudo-text for "thinking" animation (avoid randomness that changes every render)
const THINKING_PSEUDO_TEXT = [
  'Analyzing the context and formulating a response...',
  'Processing your request with care and attention...',
  'Considering multiple perspectives on this topic...',
  'Gathering relevant information to provide insight...',
  'Synthesizing ideas to craft a thoughtful reply...',
  'Examining the nuances of your question...',
  'Building upon the conversation context...',
  'Working through the reasoning step by step...',
];

/**
 * ThinkingWindow - blurred scrolling pseudo-text overlay during AI streaming.
 * Respects prefers-reduced-motion with a simple fallback.
 */
function ThinkingWindow() {
  return (
    <div className="thinking-window" contentEditable={false} aria-hidden="true">
      {/* Animated version - hidden for reduced motion */}
      <div className="thinking-window-scroll" aria-hidden="true">
        {/* Repeat text twice for seamless loop */}
        {[...THINKING_PSEUDO_TEXT, ...THINKING_PSEUDO_TEXT].map((text, i) => (
          <p key={i} className="thinking-window-line">{text}</p>
        ))}
      </div>
      {/* Reduced motion fallback */}
      <div className="thinking-window-fallback">
        <span>Thinking</span>
        <span className="thinking-dots">
          <span>.</span><span>.</span><span>.</span>
        </span>
      </div>
    </div>
  );
}

// Info icon SVG component (copied from BlockWrapper)
function InfoIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="10" />
      <line x1="12" y1="16" x2="12" y2="12" />
      <line x1="12" y1="8" x2="12.01" y2="8" />
    </svg>
  );
}

// Drag handle SVG component
function DragHandleIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor">
      <circle cx="4" cy="3" r="1.5" />
      <circle cx="10" cy="3" r="1.5" />
      <circle cx="4" cy="7" r="1.5" />
      <circle cx="10" cy="7" r="1.5" />
      <circle cx="4" cy="11" r="1.5" />
      <circle cx="10" cy="11" r="1.5" />
    </svg>
  );
}

/**
 * CellBlockView - React NodeView for rendering cell blocks.
 *
 * Renders controls similar to BlockWrapper (info button, drag handle, live indicators)
 * with NodeViewContent for the editable content area.
 *
 * Controls use contentEditable={false} to not interfere with text selection.
 *
 * Slice 05: Subscribes to store for streaming/refreshing indicators.
 * Slice 08: Implements drag reorder via drag handle.
 */
export function CellBlockView({ node, updateAttributes, editor }: NodeViewProps) {
  const [isHovered, setIsHovered] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const [isDragTarget, setIsDragTarget] = useState(false);

  const { id } = node.attrs;

  // Single "open overlay" state shared across all NodeViews.
  // This keeps the overlay positioning local (inside `cell-block-wrapper`) while avoiding
  // parent prop-drilling from the top-level stream editor.
  const overlayCellId = useBlockStore((s) => s.overlayCellId);
  const openOverlay = useBlockStore((s) => s.openOverlay);
  const closeOverlay = useBlockStore((s) => s.closeOverlay);
  const showOverlay = Boolean(id && overlayCellId === id);

  // Canonical cell data from store (attrs can be stale)
  // NOTE: We access s.blocks.get(id) directly instead of s.getBlock(id) because
  // getBlock uses get() internally which bypasses Zustand's subscription tracking.
  // This ensures re-renders when the cell data changes (e.g., model/live toggles).
  const cell = useBlockStore((s) => (id ? s.blocks.get(id) : undefined));

  // IMPORTANT: node.attrs can be stale for dynamic data (type/model/live) because we don't
  // always update node attrs when store changes. Use store as source of truth for UI chrome.
  const cellType = cell?.type ?? node.attrs.type;
  const modelId = cell?.modelId ?? node.attrs.modelId;
  const processingTrigger = cell?.processingConfig?.refreshTrigger;
  const isLive = processingTrigger === 'onStreamOpen';
  const hasDependencies = processingTrigger === 'onDependencyChange';

  const isAiBlock = cellType === 'aiResponse';

  // Subscribe to streaming/refreshing state for this cell
  const isStreaming = useBlockStore((s) => s.isStreaming(id));
  const isRefreshing = useBlockStore((s) => s.isRefreshing(id));
  const showSpinner = isStreaming || isRefreshing;

  const handleScrollToCell = useCallback((cellId: string) => {
    const el = document.querySelector(`[data-cell-id="${cellId}"]`);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, []);

  const handleToggleLive = (nextIsLive: boolean) => {
    if (!id) return;
    const store = useBlockStore.getState();
    const cell = store.getBlock(id);
    if (!cell) return;

    const nextConfig = nextIsLive
      ? { ...cell.processingConfig, refreshTrigger: 'onStreamOpen' as const }
      : { ...cell.processingConfig, refreshTrigger: undefined };

    store.updateBlock(id, { processingConfig: nextConfig });

    // Keep node attrs roughly in sync for serialization/debugging.
    // (UI reads from store; attrs are secondary.)
    updateAttributes({
      isLive: nextIsLive,
      hasDependencies: false,
    });

    // Persist immediately — content didn't change, so debounced content saves won't fire.
    bridge.send({
      type: 'saveCell',
      payload: {
        id,
        streamId: cell.streamId,
        content: cell.content,
        type: cell.type,
        order: cell.order,
        originalPrompt: cell.originalPrompt,
        modelId: cell.modelId,
        processingConfig: nextConfig,
        references: cell.references,
        blockName: cell.blockName,
        sourceApp: cell.sourceApp,
        modifiers: cell.modifiers,
        sourceBinding: cell.sourceBinding,
      },
    });
  };

  /**
   * Overlay "regenerate" handler.
   *
   * Mirrors stream-level "think/regenerate" semantics, but takes an explicit prompt string.
   * This keeps overlay behavior consistent without introducing a fragile NodeView->parent callback.
   */
  const handleRegenerate = useCallback((newPrompt: string) => {
    if (!id) return;
    const prompt = newPrompt.trim();
    if (!prompt) return;

    const store = useBlockStore.getState();
    const cell = store.getBlock(id);
    if (!cell) return;

    // Preserve images visually while streaming.
    const images = extractImages(cell.content);
    const imageBlock = buildImageBlock(images);
    const currentCellImageURLs = extractImageURLs(cell.content);

    // Prior cells for context (exclude current cell)
    const cells = store.getBlocksArray();
    const cellIndex = cells.findIndex((c) => c.id === id);
    const priorCells = cellIndex > 0 ? cells.slice(0, cellIndex) : [];

    store.startStreaming(id, imageBlock);
    store.updateBlock(id, {
      type: 'aiResponse',
      originalPrompt: prompt,
      content: imageBlock || '<p></p>',
    });

    // Persist immediately (this didn't come from typing, so debounced content saves won't fire).
    bridge.send({
      type: 'saveCell',
      payload: {
        id,
        streamId: cell.streamId,
        content: imageBlock || '<p></p>',
        type: 'aiResponse',
        order: cell.order,
        originalPrompt: prompt,
        modelId: cell.modelId,
        processingConfig: cell.processingConfig,
        references: cell.references,
        blockName: cell.blockName,
        sourceApp: cell.sourceApp,
        modifiers: cell.modifiers,
        sourceBinding: cell.sourceBinding,
      },
    });

    // Swift only understands `think`.
    bridge.send({
      type: 'think',
      payload: {
        cellId: id,
        streamId: cell.streamId,
        currentCell: prompt,
        imageURLs: currentCellImageURLs,
        priorCells: priorCells.map((c) => ({
          content: stripHtml(c.content),
          type: c.type,
          imageURLs: extractImageURLs(c.content),
        })),
      },
    });

    closeOverlay();
  }, [id, closeOverlay]);

  const handleInfoClick = useCallback((e?: ReactMouseEvent) => {
    e?.preventDefault();
    e?.stopPropagation();
    if (!id) return;
    if (showOverlay) {
      closeOverlay();
    } else {
      openOverlay(id);
    }
    if (IS_DEV) debugLog('[CellBlockView] Toggle overlay for cell', { id, next: !showOverlay });
  }, [id, openOverlay, closeOverlay, showOverlay]);

  // === Drag reorder handlers (Slice 08) ===

  const handleDragStart = useCallback((e: React.DragEvent) => {
    if (!id) return;
    e.dataTransfer.effectAllowed = 'move';
    lastPointerY = e.clientY;

    // WKWebView/WebKit often requires setData to treat the gesture as a "real" drag.
    // Use an internal MIME marker + opaque text token so failed drops can't inject UUIDs.
    try {
      e.dataTransfer.setData(INTERNAL_CELL_DRAG_MIME, id);
      e.dataTransfer.setData('text/plain', INTERNAL_CELL_DRAG_TEXT);
    } catch {
      // ignore
    }

    // Hide the default drag image so it doesn't animate back on release (confusing in live-reorder UX).
    try {
      e.dataTransfer.setDragImage(transparentDragImage, 0, 0);
    } catch {
      // ignore
    }

    globalDraggedCellId = id;
    setIsDragging(true);
    document.body.classList.add('is-cell-dragging');
    const store = useBlockStore.getState();
    store.setIsReordering(true);
    startAutoscroll();
    scheduleIdleCleanup();
    if (IS_DEV) {
      debugLog('[CellBlockView] Drag start', { id });
    }
  }, [id]);

  const handleDragEnd = useCallback(() => {
    if (IS_DEV) {
      debugLog('[CellBlockView] Drag end', { globalDraggedCellId });
    }

    // Fallback persistence: if drop didn't fire (NodeView DOM churn can cause that),
    // persist on dragend.
    if (globalDraggedCellId) persistReorderToSwift();

    cleanupDragState();
    setIsDragging(false);
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    // Only handle our block drags, not text drags
    if (!globalDraggedCellId || globalDraggedCellId === id || !editor) return;

    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';

    // Track pointer Y for autoscroll
    lastPointerY = e.clientY;

    // Track current drag target for highlight
    setIsDragTarget(true);

    // Keep reorder mode "alive" even if the original drag source NodeView is unmounted.
    useBlockStore.getState().setIsReordering(true);
    scheduleIdleCleanup();

    // Decide before/after based on pointer Y for better UX.
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const position: 'before' | 'after' = e.clientY < rect.top + rect.height / 2 ? 'before' : 'after';

    // Live reorder as user drags (throttled)
    const now = Date.now();
    if (now - lastReorderTime > 100) {
      lastReorderTime = now;

      const store = useBlockStore.getState();
      const fromIdx = store.getBlockIndex(globalDraggedCellId);
      const toIdx = store.getBlockIndex(id);

      if (fromIdx !== -1 && toIdx !== -1 && fromIdx !== toIdx) {
        // Convert "before/after target" into an insertion index for `reorderBlocks()`.
        // NOTE: reorderBlocks removes first, then inserts, so we must adjust when moving down.
        let insertIdx = position === 'before' ? toIdx : toIdx + 1;
        if (fromIdx < insertIdx) insertIdx -= 1;
        if (insertIdx === fromIdx) return;

        // Move the node in ProseMirror document
        const { doc, tr } = editor.state;

        // Find positions of both cells
        const fromResult = findCellBlockById(doc, globalDraggedCellId);
        const toResult = findCellBlockById(doc, id);

        if (fromResult && toResult) {
          const { pos: fromPos, node: fromNode } = fromResult;
          const { pos: toPos, node: toNode } = toResult;

          // Delete from old position and insert at new position
          const deleteFrom = fromPos;
          const deleteTo = fromPos + fromNode.nodeSize;

          const nodeCopy = fromNode;
          const transaction = tr.delete(deleteFrom, deleteTo);

          // IMPORTANT: `toPos` comes from the pre-delete doc. If we delete a node before `toPos`,
          // the target position shifts left by fromNode.nodeSize.
          const adjustedToPos = fromPos < toPos ? toPos - fromNode.nodeSize : toPos;
          const insertPos = adjustedToPos + (position === 'after' ? toNode.nodeSize : 0);

          transaction.insert(insertPos, nodeCopy);
          editor.view.dispatch(transaction);

          // Update store order to match
          store.reorderBlocks(fromIdx, insertIdx);
          schedulePersistReorder();

          if (IS_DEV) {
            debugLog('[CellBlockView] Reordered', {
              globalDraggedCellId,
              fromIdx,
              toIdx: insertIdx,
              position,
            });
          }
        }
      }
    }
  }, [id, editor]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    // The actual reorder already happened in handleDragOver.
    // Persist on drop (more reliable than dragend when DOM nodes are moved during the drag).
    if (globalDraggedCellId) persistReorderToSwift();
    cleanupDragState();
    setIsDragging(false);
    setIsDragTarget(false);
  }, []);

  const handleDragLeave = useCallback(() => {
    setIsDragTarget(false);
  }, []);

  useEffect(() => {
    // Keep local UI state from getting "stuck" if drag terminal events are lost.
    const handleCleanup = () => {
      setIsDragging(false);
      setIsDragTarget(false);
    };
    window.addEventListener(DRAG_CLEANUP_EVENT, handleCleanup);
    return () => window.removeEventListener(DRAG_CLEANUP_EVENT, handleCleanup);
  }, []);

  return (
    <NodeViewWrapper
      className={`cell-block-wrapper ${isHovered ? 'cell-block-wrapper--hovered' : ''} ${showSpinner ? 'cell-block-wrapper--streaming' : ''} ${isDragging ? 'cell-block-wrapper--dragging' : ''} ${isDragTarget ? 'cell-block-wrapper--drag-target' : ''}`}
      data-cell-id={id}
      data-cell-type={cellType}
      data-streaming={showSpinner ? 'true' : undefined}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {/* Top-right AI metadata badge (model + live toggle) */}
      {isAiBlock && !showSpinner && (
        <div className="cell-meta-badge" contentEditable={false}>
          <span className="cell-meta-badge-label" title={modelId ? `Model: ${modelId}` : 'AI'}>
            AI
          </span>
          <button
            className={`cell-meta-live-toggle ${isLive ? 'cell-meta-live-toggle--active' : ''}`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              handleToggleLive(!isLive);
            }}
            title={isLive ? 'Live (click to disable)' : 'Click to make live'}
            type="button"
          >
            ⚡
          </button>
        </div>
      )}

      {/* Controls - left side, non-editable */}
      <div
        className={`cell-block-controls ${isHovered || showSpinner ? 'cell-block-controls--visible' : ''}`}
        contentEditable={false}
      >
        {/* Streaming/refreshing spinner */}
        {showSpinner && (
          <span className="cell-block-indicator cell-block-indicator--streaming" title={isStreaming ? 'AI is thinking...' : 'Refreshing...'}>
            <Spinner />
          </span>
        )}

        {/* Info button - only for AI cells when not streaming */}
        {isAiBlock && !showSpinner && (
          <button
            className="cell-block-info-button"
            type="button"
            onClick={handleInfoClick}
            title="View details"
          >
            <InfoIcon />
          </button>
        )}

        {/* Drag handle - Slice 08: implements drag reorder */}
        {!showSpinner && (
          <button
            className={`cell-block-drag-handle ${isDragging ? 'cell-block-drag-handle--dragging' : ''}`}
            type="button"
            title="Drag to reorder"
            draggable
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
          >
            <DragHandleIcon />
          </button>
        )}

        {/* Block type indicators */}
        {isLive && !showSpinner && (
          <span className="cell-block-indicator cell-block-indicator--live" title="Live block (refreshes on open)">
            ⚡
          </span>
        )}
        {hasDependencies && !showSpinner && (
          <span className="cell-block-indicator cell-block-indicator--dependent" title="Updates when dependencies change">
            🔗
          </span>
        )}
      </div>

      {/* Thinking window overlay - shown during streaming/refreshing */}
      {showSpinner && <ThinkingWindow />}

      {/* NOTE: Restatement is now part of the content (as ## heading), not a separate field.
          The model outputs "## Heading\n\nBody" which becomes <h2>Heading</h2><p>Body</p> via markdownToHtml.
          This makes the heading editable/deletable like normal content (Option A from ALPHA_STABILITY_PLAN.md). */}

      {/* Content area - editable */}
      <NodeViewContent className="cell-block-content" />

      {/* Info overlay - absolute positioned inside the cell wrapper */}
      {showOverlay && cell && (
        <CellOverlay
          cell={cell}
          onClose={closeOverlay}
          onScrollToCell={handleScrollToCell}
          onToggleLive={handleToggleLive}
          onRegenerate={handleRegenerate}
        />
      )}
    </NodeViewWrapper>
  );
}
