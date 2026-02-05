import { useState, useRef, useEffect, useCallback } from 'react';
import { Cell as CellType } from '../types';
import { CellEditor } from './CellEditor';
import { useBlockStore } from '../store/blockStore';
import { findByShortIdOrName } from '../utils/references';
import { extractFirstHeadingFromHtml } from '../utils/cellTitle';

interface CellProps {
  cell: CellType;
  isNew?: boolean;
  isStreaming?: boolean;
  isRefreshing?: boolean;
  isFirstEmptyCell?: boolean; // Show placeholder only for first cell of empty document
  error?: string;
  onUpdate: (content: string) => void;
  onDelete: () => void;
  onEnter: () => void;
  onThink: () => void;
  onFocusPrevious: () => void;
  onFocusNext: () => void;
  registerFocus: (focus: () => void) => void;
  onScrollToCell?: (cellId: string) => void;
  onOpenOverlay?: () => void;
  onToggleLive?: (isLive: boolean) => void;
}

export function Cell({
  cell,
  isNew = false,
  isStreaming = false,
  isRefreshing = false,
  isFirstEmptyCell = false,
  error,
  onUpdate,
  onDelete,
  onEnter,
  onThink,
  onFocusPrevious,
  onFocusNext,
  registerFocus,
  onScrollToCell,
  onOpenOverlay,
  onToggleLive,
}: CellProps) {
  const [localContent, setLocalContent] = useState(cell.content);
  const [isFocused, setIsFocused] = useState(false);
  const saveTimeoutRef = useRef<number | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // Handle clicks on cell references
  const handleReferenceClick = useCallback(
    (e: React.MouseEvent) => {
      const target = e.target as HTMLElement;
      // Check if clicked on a cell-reference element (TipTap mention)
      if (target.classList.contains('cell-reference') || target.closest('.cell-reference')) {
        e.preventDefault();
        e.stopPropagation();

        // Get the reference text from data-id or text content
        const refElement = target.classList.contains('cell-reference')
          ? target
          : target.closest('.cell-reference');
        if (!refElement) return;

        // TipTap stores mention data in data-id attribute
        const refId = refElement.getAttribute('data-id');
        if (refId && onScrollToCell) {
          // Find the referenced cell by ID or short ID
          const blocks = useBlockStore.getState().blocks;
          const referencedCell = findByShortIdOrName(blocks, refId);
          if (referencedCell) {
            onScrollToCell(referencedCell.id);
          }
        }
      }
    },
    [onScrollToCell]
  );

  // Trim trailing empty paragraphs from HTML content
  const trimEmptyLines = (html: string): string => {
    return html.replace(/(<p>(\s|<br\s*\/?>)*<\/p>\s*)+$/gi, '');
  };

  // Debounced save
  const handleChange = (content: string) => {
    setLocalContent(content);

    if (saveTimeoutRef.current) {
      clearTimeout(saveTimeoutRef.current);
    }

    saveTimeoutRef.current = window.setTimeout(() => {
      if (content !== cell.content) {
        onUpdate(content);
      }
    }, 500);
  };

  // Save immediately on blur or navigation
  const saveNow = () => {
    if (saveTimeoutRef.current) {
      clearTimeout(saveTimeoutRef.current);
    }
    const trimmedContent = trimEmptyLines(localContent);
    if (trimmedContent !== localContent) {
      setLocalContent(trimmedContent);
    }
    if (trimmedContent !== cell.content) {
      onUpdate(trimmedContent);
    }
  };

  // Handle focus - also update blockStore
  const handleFocus = () => {
    setIsFocused(true);
    useBlockStore.getState().setFocus(cell.id);
  };

  // Handle blur - save content (empty cells persist like Notion for spacing)
  const handleBlur = (e: React.FocusEvent) => {
    // Check if focus is moving to another element within the same cell
    if (containerRef.current?.contains(e.relatedTarget as Node)) {
      return;
    }

    // If relatedTarget is null/undefined, check if the active element is within the cell
    // This handles cases where the new focus target isn't yet in the DOM (e.g., button clicks)
    if (!e.relatedTarget) {
      // Use a microtask to check after the click completes
      queueMicrotask(() => {
        if (containerRef.current?.contains(document.activeElement)) {
          return;
        }
        setIsFocused(false);
        useBlockStore.getState().setFocus(null);
        saveNow();
      });
      return;
    }

    setIsFocused(false);
    useBlockStore.getState().setFocus(null);
    saveNow();
  };

  // Handle delete - save first, then delete
  const handleBackspaceEmpty = () => {
    saveNow();
    onDelete();
  };

  // Register focus handler for parent
  useEffect(() => {
    registerFocus(() => {
      containerRef.current?.querySelector<HTMLElement>('.ProseMirror')?.focus();
    });
  }, [registerFocus]);

  // Cleanup timeout on unmount
  useEffect(() => {
    return () => {
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
    };
  }, []);

  // Sync local content with cell prop (for streaming updates)
  useEffect(() => {
    // For AI cells, always sync since user doesn't edit them directly
    // For text cells, only sync if not focused (to avoid interrupting typing)
    const isAiCell = cell.type === 'aiResponse';
    const shouldSync = isStreaming || isAiCell || !isFocused;
    if (shouldSync) {
      setLocalContent(cell.content);
    }
  }, [cell.content, cell.type, isStreaming, isFocused]);

  const cellTypeClass = cell.type === 'aiResponse'
    ? 'cell--ai'
    : cell.type === 'quote'
      ? 'cell--quote'
      : '';

  const streamingClass = isStreaming ? 'cell--streaming' : '';
  const refreshingClass = isRefreshing ? 'cell--refreshing' : '';
  const errorClass = error ? 'cell--error' : '';

  // Title view (for legacy list-style cells): show the first heading when present.
  const headingTitle = extractFirstHeadingFromHtml(cell.content);
  const showTitleView = Boolean(headingTitle) && !isFocused && !isNew && cell.type === 'text';

  const isAiCell = cell.type === 'aiResponse';
  const isLive = cell.processingConfig?.refreshTrigger === 'onStreamOpen';

  return (
    <div
      ref={containerRef}
      className={`cell ${cellTypeClass} ${streamingClass} ${refreshingClass} ${errorClass}`}
      onBlur={handleBlur}
      onFocus={handleFocus}
      onClick={handleReferenceClick}
    >
      {/* Hover metadata badge for AI cells */}
      {isAiCell && !isStreaming && (
        <div className="cell-meta-badge">
          <span
            className="cell-meta-badge-label"
            title={cell.modelId ? `Model: ${cell.modelId}` : 'AI'}
            onClick={(e) => {
              e.stopPropagation();
              onOpenOverlay?.();
            }}
          >
            AI
          </span>
          <button
            className={`cell-meta-live-toggle ${isLive ? 'cell-meta-live-toggle--active' : ''}`}
            onClick={(e) => {
              e.stopPropagation();
              onToggleLive?.(!isLive);
            }}
            title={isLive ? 'Live (click to disable)' : 'Click to make live'}
          >
            ⚡
          </button>
        </div>
      )}

      {/* Show error banner above content, not replacing it */}
      {error && (
        <div className="cell-error-banner">
          <span className="cell-error-icon">!</span>
          <span className="cell-error-text">{error}</span>
          <button className="cell-error-dismiss" onClick={() => useBlockStore.getState().clearError(cell.id)}>
            Dismiss
          </button>
        </div>
      )}

      {showTitleView ? (
        // Display mode: show the heading-derived title
        <div
          className="cell-restatement"
          onClick={() => {
            setIsFocused(true);
            setTimeout(() => {
              containerRef.current?.querySelector<HTMLElement>('.ProseMirror')?.focus();
            }, 0);
          }}
        >
          {headingTitle}
        </div>
      ) : (
        <>
          <CellEditor
            content={localContent}
            autoFocus={isNew || isFocused}
            placeholder={isFirstEmptyCell ? 'Write your thoughts...' : ''}
            cellId={cell.id}
            streamId={cell.streamId}
            onChange={handleChange}
            onEnter={onEnter}
            onThink={() => { saveNow(); onThink(); }}
            onBackspaceEmpty={handleBackspaceEmpty}
            onArrowUp={() => { saveNow(); onFocusPrevious(); }}
            onArrowDown={() => { saveNow(); onFocusNext(); }}
          />
        </>
      )}
    </div>
  );
}
