import { useRef, useCallback, useEffect, useState } from 'react';
import { Stream, Cell as CellType, SourceReference, bridge } from '../types';
import { Cell } from './Cell';
import { BlockWrapper } from './BlockWrapper';
import { SidePanel } from './SidePanel';
import { SearchModal } from './SearchModal';
import { ReferencePreview } from './ReferencePreview';
import { CellOverlay } from './CellOverlay';
import { stripHtml, extractImages, extractImageURLs, buildImageBlock, isEmptyCell } from '../utils/html';
import { markdownToHtml } from '../utils/markdown';
import { useBlockStore } from '../store/blockStore';
import { useBlockFocus } from '../hooks/useBlockFocus';
import { useBridgeMessages } from '../hooks/useBridgeMessages';

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

export function StreamEditor({ stream, onBack, onDelete, onNavigateToStream, pendingCellId, pendingSourceId, onClearPendingCell, onClearPendingSource }: StreamEditorProps) {
  // Use Zustand store for block state
  const store = useBlockStore();

  // Bridge message handling (AI streaming, modifiers, sources, etc.)
  const { sources, setSources } = useBridgeMessages({
    streamId: stream.id,
    initialSources: stream.sources,
  });

  // Local state for stream-level concerns
  const [title, setTitle] = useState(stream.title);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [overlayBlockId, setOverlayBlockId] = useState<string | null>(null);
  const [showSearch, setShowSearch] = useState(false);
  const [highlightedSourceId, setHighlightedSourceId] = useState<string | null>(null);

  const cellFocusRefs = useRef<Map<string, () => void>>(new Map());
  const titleInputRef = useRef<HTMLInputElement>(null);

  // Initialize store with stream data
  useEffect(() => {
    store.loadStream(stream.id, stream.cells);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stream.id]);

  // Cmd+K to open search
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setShowSearch(true);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  // Handle pending cell navigation (from cross-stream search)
  // Note: handleScrollToCell is defined with useCallback below, so this effect
  // runs after the function is available
  const pendingCellIdRef = useRef(pendingCellId);
  pendingCellIdRef.current = pendingCellId;

  useEffect(() => {
    if (pendingCellIdRef.current && store.streamId === stream.id) {
      // Wait for DOM to be ready
      const cellId = pendingCellIdRef.current;
      setTimeout(() => {
        const cellElement = document.querySelector(`[data-block-id="${cellId}"]`);
        if (cellElement) {
          cellElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
          cellElement.classList.add('block-wrapper--highlighted');
          setTimeout(() => cellElement.classList.remove('block-wrapper--highlighted'), 2000);
        }
        onClearPendingCell?.();
      }, 200);
    }
  }, [store.streamId, stream.id, onClearPendingCell]);

  // Create initial cell if stream is empty
  useEffect(() => {
    const blocks = store.getBlocksArray();
    if (store.streamId === stream.id && blocks.length === 0) {
      const initialCell: CellType = {
        id: crypto.randomUUID(),
        streamId: stream.id,
        content: '',
        type: 'text',
        sourceBinding: null,
        order: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };
      store.addBlock(initialCell);
      store.setNewBlockId(initialCell.id);
      bridge.send({
        type: 'saveCell',
        payload: {
          id: initialCell.id,
          streamId: stream.id,
          content: '',
          type: 'text',
          order: 0,
        },
      });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store.streamId, stream.id]);

  // Track if we've done initial load (for pruning trailing empties only on load)
  const hasInitializedRef = useRef(false);

  // Ensure at least one trailing empty cell exists
  // - On initial load: prune extra trailing empty cells to just one
  // - During editing: only add if there's no trailing empty (user can create many by pressing Enter)
  useEffect(() => {
    if (store.streamId !== stream.id) return;

    const blocks = store.getBlocksArray();
    if (blocks.length === 0) return;

    // Count trailing empty cells
    let trailingEmptyCount = 0;
    for (let i = blocks.length - 1; i >= 0; i--) {
      if (isEmptyCell(blocks[i].content) && blocks[i].type === 'text') {
        trailingEmptyCount++;
      } else {
        break;
      }
    }

    // If no trailing empty cell, add one (always, during editing or initial load)
    if (trailingEmptyCount === 0) {
      const lastBlock = blocks[blocks.length - 1];
      const newCell: CellType = {
        id: crypto.randomUUID(),
        streamId: stream.id,
        content: '',
        type: 'text',
        sourceBinding: null,
        order: lastBlock.order + 1,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };
      store.addBlock(newCell, lastBlock.id);
      bridge.send({
        type: 'saveCell',
        payload: {
          id: newCell.id,
          streamId: stream.id,
          content: '',
          type: 'text',
          order: newCell.order,
        },
      });
    }
    // Only prune extra trailing empty cells on initial load, not during editing
    // This allows users to create spacing by pressing Enter multiple times
    else if (trailingEmptyCount > 1 && !hasInitializedRef.current) {
      // Delete all but the last trailing empty cell
      for (let i = blocks.length - trailingEmptyCount; i < blocks.length - 1; i++) {
        const cellToDelete = blocks[i];
        store.deleteBlock(cellToDelete.id);
        bridge.send({ type: 'deleteCell', payload: { id: cellToDelete.id } });
      }
    }

    // Mark as initialized after first run
    if (!hasInitializedRef.current) {
      hasInitializedRef.current = true;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store.blocks, store.streamId, stream.id]);

  // Reset initialization flag when stream changes
  useEffect(() => {
    hasInitializedRef.current = false;
  }, [stream.id]);

  // Source callbacks for SourcePanel
  const handleSourceAdded = useCallback((source: SourceReference) => {
    setSources(prev => [...prev, source]);
  }, [setSources]);

  const handleSourceRemoved = useCallback((sourceId: string) => {
    setSources(prev => prev.filter(s => s.id !== sourceId));
  }, [setSources]);

  const handleCellUpdate = useCallback((cellId: string, content: string) => {
    const cell = store.getBlock(cellId);
    if (cell) {
      store.updateBlock(cellId, { content });

      // Save to Swift with all fields preserved
      bridge.send({
        type: 'saveCell',
        payload: {
          id: cellId,
          streamId: stream.id,
          content,
          type: cell.type,
          order: cell.order,
          originalPrompt: cell.originalPrompt,
          restatement: cell.restatement,
          modelId: cell.modelId,
          processingConfig: cell.processingConfig,
          modifiers: cell.modifiers,
          sourceApp: cell.sourceApp,
          references: cell.references,
          blockName: cell.blockName,
          sourceBinding: cell.sourceBinding,
        },
      });
    }
  }, [stream.id, store]);

  // Shared helper for dispatching AI requests (used by handleThink and handleRegenerate)
  const dispatchAIRequest = useCallback((
    cellId: string,
    prompt: string,
    cellContent: string,
    cellOrder: number,
    isNewCell: boolean // true for handleThink (transforms cell), false for regenerate
  ) => {
    const cells = store.getBlocksArray();
    const cellIndex = cells.findIndex(c => c.id === cellId);
    const cell = store.getBlock(cellId);

    // Extract images from the cell content - these will be preserved visually
    const images = extractImages(cellContent);
    const imageBlock = buildImageBlock(images);

    // Extract image URLs for sending to the AI (will be converted to data URLs on Swift side)
    const currentCellImageURLs = extractImageURLs(cellContent);

    // Gather prior cells for context (exclude current cell and empty spacing cells)
    // Include image URLs for vision model support
    const priorCells = cells
      .slice(0, cellIndex)
      .filter(c => !isEmptyCell(c.content))
      .map(c => ({
        id: c.id,
        content: c.content,
        type: c.type,
        imageURLs: extractImageURLs(c.content),
      }));

    // Update cell state
    const updates = isNewCell
      ? { type: 'aiResponse' as const, originalPrompt: prompt, content: imageBlock, restatement: undefined }
      : { originalPrompt: prompt, content: imageBlock, restatement: undefined };
    store.updateBlock(cellId, updates);

    // Save cell (preserve sourceApp and references from Quick Panel)
    bridge.send({
      type: 'saveCell',
      payload: {
        id: cellId,
        streamId: stream.id,
        content: imageBlock,
        type: 'aiResponse',
        originalPrompt: prompt,
        order: cellOrder,
        sourceApp: cell?.sourceApp,
        references: cell?.references,
      },
    });

    // Start streaming with preserved images
    store.startStreaming(cellId, imageBlock);
    store.clearError(cellId);

    // Send think request with full context (including image URLs for vision)
    bridge.send({
      type: 'think',
      payload: {
        cellId,
        streamId: stream.id,
        currentCell: prompt,
        imageURLs: currentCellImageURLs,  // Images in current cell
        priorCells: priorCells.map(c => ({
          content: stripHtml(c.content),
          type: c.type,
          imageURLs: c.imageURLs,  // Images in prior cells
        })),
      },
    });
  }, [stream.id, store]);

  // Cmd+Enter: Transform current cell into AI response
  const handleThink = useCallback((cellId: string) => {
    const currentCell = store.getBlock(cellId);
    const originalPrompt = stripHtml(currentCell?.content || '').trim();
    if (!currentCell || !originalPrompt) return;

    dispatchAIRequest(cellId, originalPrompt, currentCell.content, currentCell.order, true);
  }, [store, dispatchAIRequest]);

  const handleCellDelete = useCallback((cellId: string) => {
    const cells = store.getBlocksArray();
    const index = cells.findIndex(c => c.id === cellId);
    if (index === -1) return;

    // Don't delete if it's the only cell
    if (cells.length === 1) return;

    store.deleteBlock(cellId);
    bridge.send({ type: 'deleteCell', payload: { id: cellId } });

    // Focus previous cell or next if deleting first
    const focusIndex = index > 0 ? index - 1 : 0;
    const focusId = cells[focusIndex]?.id;
    if (focusId && focusId !== cellId) {
      setTimeout(() => {
        cellFocusRefs.current.get(focusId)?.();
      }, 0);
    }
  }, [store]);

  // Block focus management for keyboard navigation
  const { focusedBlockId } = useBlockFocus({
    onDeleteBlock: handleCellDelete,
  });

  // When focusedBlockId changes (from keyboard nav), actually focus the DOM element
  useEffect(() => {
    if (focusedBlockId) {
      const focusFn = cellFocusRefs.current.get(focusedBlockId);
      if (focusFn) {
        focusFn();
      }
    }
  }, [focusedBlockId]);

  const handleCreateCell = useCallback((afterIndex: number) => {
    const newCell: CellType = {
      id: crypto.randomUUID(),
      streamId: stream.id,
      content: '',
      type: 'text',
      sourceBinding: null,
      order: afterIndex + 1,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    const cells = store.getBlocksArray();
    const afterId = cells[afterIndex]?.id;
    store.addBlock(newCell, afterId);
    store.setNewBlockId(newCell.id);

    bridge.send({
      type: 'saveCell',
      payload: {
        id: newCell.id,
        streamId: stream.id,
        content: '',
        type: 'text',
        order: afterIndex + 1,
      },
    });
  }, [stream.id, store]);

  const handleFocusPrevious = useCallback((currentIndex: number) => {
    const cells = store.getBlocksArray();
    if (currentIndex > 0) {
      const prevId = cells[currentIndex - 1]?.id;
      if (prevId) {
        cellFocusRefs.current.get(prevId)?.();
      }
    }
  }, [store]);

  const handleFocusNext = useCallback((currentIndex: number) => {
    const cells = store.getBlocksArray();
    if (currentIndex < cells.length - 1) {
      const nextId = cells[currentIndex + 1]?.id;
      if (nextId) {
        cellFocusRefs.current.get(nextId)?.();
      }
    }
  }, [store]);

  const registerCellFocus = useCallback((cellId: string, focus: () => void) => {
    cellFocusRefs.current.set(cellId, focus);
  }, []);

  // Open overlay for a cell
  const handleOpenOverlay = useCallback((cellId: string) => {
    setOverlayBlockId(cellId);
  }, []);

  // Close overlay
  const handleCloseOverlay = useCallback(() => {
    setOverlayBlockId(null);
  }, []);

  // Toggle live status for a cell
  const handleToggleLive = useCallback((cellId: string, isLive: boolean) => {
    const cell = store.getBlock(cellId);
    if (!cell) return;

    // Build the new processing config
    const newConfig = isLive
      ? { ...cell.processingConfig, refreshTrigger: 'onStreamOpen' as const }
      : { ...cell.processingConfig, refreshTrigger: undefined };

    // Update local state
    store.updateBlock(cellId, { processingConfig: newConfig });

    // Persist to backend (preserve all metadata)
    bridge.send({
      type: 'saveCell',
      payload: {
        id: cellId,
        streamId: stream.id,
        content: cell.content,
        type: cell.type,
        order: cell.order,
        originalPrompt: cell.originalPrompt,
        restatement: cell.restatement,
        modelId: cell.modelId,
        processingConfig: newConfig,
        modifiers: cell.modifiers,
        sourceApp: cell.sourceApp,
        references: cell.references,
        blockName: cell.blockName,
        sourceBinding: cell.sourceBinding,
      },
    });
  }, [stream.id, store]);

  // Regenerate an AI cell with a new/edited prompt
  const handleRegenerate = useCallback((cellId: string, newPrompt: string) => {
    const cell = store.getBlock(cellId);
    if (!cell || cell.type !== 'aiResponse') return;

    dispatchAIRequest(cellId, newPrompt, cell.content, cell.order, false);
  }, [store, dispatchAIRequest]);

  // Scroll to a cell by ID (used for reference navigation)
  const handleScrollToCell = useCallback((cellId: string) => {
    // Find the cell element in the DOM
    const cellElement = document.querySelector(`[data-block-id="${cellId}"]`);
    if (cellElement) {
      // Scroll the cell into view
      cellElement.scrollIntoView({ behavior: 'smooth', block: 'center' });

      // Add a brief highlight animation
      cellElement.classList.add('block-wrapper--highlighted');
      setTimeout(() => {
        cellElement.classList.remove('block-wrapper--highlighted');
      }, 2000);

      // Focus the cell
      const focusFn = cellFocusRefs.current.get(cellId);
      if (focusFn) {
        setTimeout(() => focusFn(), 300); // Wait for scroll to complete
      }
    }
  }, []);

  // Navigate to a source in the source panel (for chunk search results)
  const handleNavigateToSource = useCallback((sourceId: string) => {
    setHighlightedSourceId(sourceId);
  }, []);

  // Title editing handlers
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

  // Get cells from store for rendering
  const cells = store.getBlocksArray();
  const newBlockId = store.newBlockId;

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
        <span className="stream-hint">Cmd+Enter to think with AI</span>
        <button
          onClick={() => setShowDeleteConfirm(true)}
          className="delete-stream-button"
          title="Delete stream"
        >
          Delete
        </button>
      </header>

      {/* Delete confirmation dialog */}
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
        <div
          className="stream-content"
          onDragOver={(e) => e.preventDefault()}
          onDrop={(e) => e.preventDefault()}
        >
          {cells.map((cell, index) => {
            const isStreaming = store.isStreaming(cell.id);
            const isRefreshing = store.isRefreshing(cell.id);
            const error = store.getError(cell.id);
            const streamingContent = store.getStreamingContent(cell.id);
            const refreshingContent = store.getRefreshingContent(cell.id);
            const preservedImages = store.getPreservedImages(cell.id);

            // Convert streaming/refreshing markdown to HTML for display
            // Prepend preserved images so they stay visible during streaming
            let displayContent = cell.content;
            if (isStreaming && streamingContent) {
              const imagesPrefix = preservedImages || '';
              displayContent = imagesPrefix + markdownToHtml(streamingContent);
            } else if (isRefreshing && refreshingContent) {
              displayContent = markdownToHtml(refreshingContent);
            }

            const showOverlay = overlayBlockId === cell.id;

            // Check if this is the first empty cell of an empty document (for showing placeholder)
            const isFirstEmptyCell = index === 0 &&
              cells.length === 1 &&
              isEmptyCell(cell.content) &&
              cell.type === 'text';

            return (
              <BlockWrapper
                key={cell.id}
                id={cell.id}
                onInfoClick={() => handleOpenOverlay(cell.id)}
              >
                <Cell
                  cell={(isStreaming || isRefreshing) ? { ...cell, content: displayContent } : cell}
                  isNew={cell.id === newBlockId}
                  isStreaming={isStreaming}
                  isRefreshing={isRefreshing}
                  isFirstEmptyCell={isFirstEmptyCell}
                  error={error}
                  onUpdate={(content) => handleCellUpdate(cell.id, content)}
                  onDelete={() => handleCellDelete(cell.id)}
                  onEnter={() => handleCreateCell(index)}
                  onThink={() => handleThink(cell.id)}
                  onFocusPrevious={() => handleFocusPrevious(index)}
                  onFocusNext={() => handleFocusNext(index)}
                  registerFocus={(focus) => registerCellFocus(cell.id, focus)}
                  onScrollToCell={handleScrollToCell}
                  onOpenOverlay={() => handleOpenOverlay(cell.id)}
                  onToggleLive={(isLive) => handleToggleLive(cell.id, isLive)}
                />
                {showOverlay && (
                  <CellOverlay
                    cell={cell}
                    onClose={handleCloseOverlay}
                    onScrollToCell={handleScrollToCell}
                    onToggleLive={(isLive) => handleToggleLive(cell.id, isLive)}
                    onRegenerate={(newPrompt) => handleRegenerate(cell.id, newPrompt)}
                  />
                )}
              </BlockWrapper>
            );
          })}
        </div>

        <SidePanel
          cells={cells}
          focusedCellId={focusedBlockId}
          onCellClick={handleScrollToCell}
          streamId={stream.id}
          sources={sources}
          onSourceAdded={handleSourceAdded}
          onSourceRemoved={handleSourceRemoved}
          highlightedSourceId={highlightedSourceId || pendingSourceId}
          onClearHighlight={() => {
            setHighlightedSourceId(null);
            onClearPendingSource?.();
          }}
        />
      </div>

      {/* Global reference preview tooltip */}
      <ReferencePreview onScrollToCell={handleScrollToCell} />

      {/* Search modal */}
      <SearchModal
        isOpen={showSearch}
        onClose={() => setShowSearch(false)}
        currentStreamId={stream.id}
        onNavigateToCell={handleScrollToCell}
        onNavigateToStream={onNavigateToStream || (() => {})}
        onNavigateToSource={handleNavigateToSource}
      />
    </div>
  );
}
