import { useEffect, useRef, useCallback, useState } from 'react';
import { Cell } from '../types';
import { PromptEditor } from './PromptEditor';
import { useBlockStore } from '../store/blockStore';
import { deriveCellTitle } from '../utils/cellTitle';

interface CellOverlayProps {
  cell: Cell;
  onClose: () => void;
  onScrollToCell?: (cellId: string) => void;
  onToggleLive?: (isLive: boolean) => void;
  onRegenerate?: (newPrompt: string) => void;
}

/**
 * Frosted glass overlay showing cell metadata:
 * - Original prompt (editable)
 * - Model used and timestamp
 * - Live status indicator
 * - Cells that reference this cell
 */
export function CellOverlay({
  cell,
  onClose,
  onScrollToCell,
  onToggleLive,
  onRegenerate,
}: CellOverlayProps) {
  const overlayRef = useRef<HTMLDivElement>(null);
  const promptEditorRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const blocks = useBlockStore((state) => state.blocks);

  // Local state for editable prompt (stored as HTML for TipTap)
  const [editedPromptHtml, setEditedPromptHtml] = useState(
    // Convert plain text to simple HTML paragraph
    cell.originalPrompt ? `<p>${cell.originalPrompt}</p>` : ''
  );

  // Find cells that reference this cell
  // NOTE: `blocks` is a Map in zustand store (Slice 03+).
  // Use `.values()` rather than `Object.values()` so this works in both legacy + unified.
  const referencingCells = Array.from(blocks.values()).filter((block) => {
    if (!block.references || block.id === cell.id) return false;
    return block.references.includes(cell.id);
  });

  // Helper to extract plain text from HTML
  const htmlToPlainText = useCallback((html: string) => {
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    return tmp.textContent || tmp.innerText || '';
  }, []);

  // Focus sensible control on mount
  useEffect(() => {
    // Use rAF to ensure DOM is ready (TipTap editor may need time to mount)
    const raf = requestAnimationFrame(() => {
      if (cell.type === 'aiResponse' && promptEditorRef.current) {
        // Focus the prompt editor for AI cells.
        // .prompt-editor-content is the contenteditable element rendered by PromptEditor's TipTap instance.
        const editorEl = promptEditorRef.current.querySelector('.prompt-editor-content') as HTMLElement;
        editorEl?.focus();
      } else {
        // Focus close button for non-AI cells
        closeButtonRef.current?.focus();
      }
    });
    return () => cancelAnimationFrame(raf);
  }, []); // Only run on mount

  // Close on ESC key (but not when editing prompt)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        // If focus is inside the prompt editor, blur it first
        if (promptEditorRef.current?.contains(document.activeElement)) {
          (document.activeElement as HTMLElement)?.blur();
        } else {
          onClose();
        }
      }
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  // Handle regenerate
  const handleRegenerate = useCallback(() => {
    const plainText = htmlToPlainText(editedPromptHtml).trim();
    if (plainText && onRegenerate) {
      onRegenerate(plainText);
      onClose();
    }
  }, [editedPromptHtml, htmlToPlainText, onRegenerate, onClose]);

  // NOTE: We intentionally do NOT close on outside click.
  // In unified mode the overlay sits inside a ProseMirror NodeView, and "click outside"
  // is both easy to mis-detect (due to event retargeting) and undesirable UX.
  //
  // Close rules (per request):
  // - ESC
  // - explicit X button
  // - clicking the info icon again (handled by the caller)

  const handleReferenceClick = useCallback(
    (cellId: string) => {
      if (onScrollToCell) {
        onScrollToCell(cellId);
        onClose();
      }
    },
    [onScrollToCell, onClose]
  );

  // Format timestamp
  const formatDate = (timestamp?: string) => {
    if (!timestamp) return 'Unknown';
    const date = new Date(timestamp);
    return date.toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    });
  };

  // Get metadata from cell
  const timestamp = cell.updatedAt || cell.createdAt;
  const modelId = cell.modelId;
  const isLive = cell.processingConfig?.refreshTrigger === 'onStreamOpen';
  const hasDependencyRefresh = cell.processingConfig?.refreshTrigger === 'onDependencyChange';

  return (
    <div className="cell-overlay" ref={overlayRef} contentEditable={false}>
      {/* Header with close button */}
      <div className="cell-overlay-header">
        <span className="cell-overlay-title">Cell Details</span>
        <button ref={closeButtonRef} className="cell-overlay-close" onClick={onClose}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="18" y1="6" x2="6" y2="18" />
            <line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>

      {/* Original prompt (editable for AI cells, with @ reference support) */}
      {cell.type === 'aiResponse' && (
        <div className="cell-overlay-section">
          <div className="cell-overlay-label">Prompt</div>
          <div className="cell-overlay-prompt-row" ref={promptEditorRef}>
            <PromptEditor
              content={editedPromptHtml}
              cellId={cell.id}
              placeholder="Enter a prompt..."
              onChange={setEditedPromptHtml}
              onSubmit={handleRegenerate}
            />
            <button
              className="cell-overlay-regenerate"
              onClick={handleRegenerate}
              disabled={!htmlToPlainText(editedPromptHtml).trim()}
              title="Regenerate (Enter)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 11-9-9c2.52 0 4.93 1 6.74 2.74L21 8" />
                <path d="M21 3v5h-5" />
              </svg>
            </button>
          </div>
        </div>
      )}

      {/* Metadata row */}
      <div className="cell-overlay-section">
        <div className="cell-overlay-meta">
          <span className="cell-overlay-model">{modelId || 'AI'}</span>
          <span className="cell-overlay-separator">·</span>
          <span className="cell-overlay-time">{formatDate(timestamp)}</span>
          {isLive && (
            <>
              <span className="cell-overlay-separator">·</span>
              <span className="cell-overlay-live" title="Refreshes when stream opens">
                Live
              </span>
            </>
          )}
          {hasDependencyRefresh && (
            <>
              <span className="cell-overlay-separator">·</span>
              <span className="cell-overlay-dependency" title="Updates when dependencies change">
                Auto-refresh
              </span>
            </>
          )}
        </div>
      </div>

      {/* Live toggle */}
      {cell.type === 'aiResponse' && (
        <div className="cell-overlay-section">
          <div className="cell-overlay-label">Live Refresh</div>
          <button
            className={`cell-overlay-live-toggle ${isLive ? 'cell-overlay-live-toggle--active' : ''}`}
            onClick={() => onToggleLive?.(!isLive)}
          >
            <span className="cell-overlay-live-icon">⚡</span>
            <span className="cell-overlay-live-text">
              {isLive ? 'Live — refreshes when stream opens' : 'Not live — click to enable'}
            </span>
          </button>
        </div>
      )}

      {/* Referencing cells */}
      {referencingCells.length > 0 && (
        <div className="cell-overlay-section">
          <div className="cell-overlay-label">Referenced by</div>
          <div className="cell-overlay-references">
            {referencingCells.map((refCell) => (
              <button
                key={refCell.id}
                className="cell-overlay-ref-link"
                onClick={() => handleReferenceClick(refCell.id)}
              >
                {deriveCellTitle(refCell)}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
