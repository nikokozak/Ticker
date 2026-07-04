import { useState, useEffect, useCallback, useRef, forwardRef, useMemo } from 'react';
import { Cell, CellType, SourceReference, bridge } from '../types';
import { useToastStore } from '../store/toastStore';
import { deriveCellTitle, extractFirstHeadingFromHtml } from '../utils/cellTitle';

type Tab = 'outline' | 'sources';

interface SidePanelProps {
  // Outline props
  cells: Cell[];
  focusedCellId: string | null;
  onCellClick: (cellId: string) => void;
  // Source props
  streamId: string;
  sources: SourceReference[];
  onSourceAdded?: (source: SourceReference) => void;
  onSourceRemoved: (sourceId: string) => void;
  onSourceOpen?: (source: SourceReference) => void;
  highlightedSourceId?: string | null;
  onClearHighlight?: () => void;
}

export function SidePanel({
  cells,
  focusedCellId,
  onCellClick,
  streamId,
  sources,
  onSourceRemoved,
  onSourceOpen,
  highlightedSourceId,
  onClearHighlight,
}: SidePanelProps) {
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [activeTab, setActiveTab] = useState<Tab>('sources');
  const [error, setError] = useState<string | null>(null);
  const [pendingRemoval, setPendingRemoval] = useState<string | null>(null);
  const [isDragOver, setIsDragOver] = useState(false);
  const sourceRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const addToast = useToastStore((state) => state.addToast);

  // Filter out empty cells from outline
  const outlineCells = useMemo(() => {
    return cells.filter(cell => {
      // Check if cell has meaningful content
      if (cell.blockName) return true;
      if (extractFirstHeadingFromHtml(cell.content)) return true;
      if (cell.originalPrompt) return true;
      // Strip HTML and check for actual text content
      const stripped = stripHtml(cell.content).trim();
      return stripped.length > 0;
    });
  }, [cells]);

  // Source handlers
  const handleAddSource = () => {
    setError(null);
    bridge.send({ type: 'addSource', payload: { streamId } });
  };

  const handleRemoveSource = (id: string) => {
    setError(null);
    setPendingRemoval(id);
    bridge.send({ type: 'removeSource', payload: { id } });
  };

  const showError = (message: string) => {
    setError(message);
    setTimeout(() => setError(null), 5000);
    // Surface source errors globally so they're visible even when the panel is collapsed.
    addToast(message, 'error');
  };

  // Drag and drop handlers
  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (e.dataTransfer.types.includes('Files')) {
      e.dataTransfer.dropEffect = 'copy';
      setIsDragOver(true);
      // Switch to sources tab when dragging files
      if (activeTab !== 'sources') {
        setActiveTab('sources');
      }
    }
  }, [activeTab]);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX;
    const y = e.clientY;
    if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) {
      setIsDragOver(false);
    }
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragOver(false);
  }, []);

  // Listen for source events from bridge
  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'sourceError' && message.payload?.error) {
        showError(message.payload.error as string);
        setActiveTab('sources');
      }
      if (message.type === 'sourceRemoved' && message.payload?.id) {
        const removedId = message.payload.id as string;
        setPendingRemoval(null);
        onSourceRemoved(removedId);
      }
      if (message.type === 'sourceRemoveError' && message.payload?.error) {
        setPendingRemoval(null);
        showError(message.payload.error as string);
      }
    });
    return unsubscribe;
  }, [onSourceRemoved]);

  // Handle source highlighting from search
  useEffect(() => {
    if (!highlightedSourceId) return;

    // Switch to sources tab and expand if needed
    setActiveTab('sources');
    if (isCollapsed) {
      setIsCollapsed(false);
    }

    const timer = setTimeout(() => {
      const sourceEl = sourceRefs.current.get(highlightedSourceId);
      if (sourceEl) {
        sourceEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
        sourceEl.classList.add('side-panel-item--highlighted');
        setTimeout(() => {
          sourceEl.classList.remove('side-panel-item--highlighted');
          onClearHighlight?.();
        }, 2000);
      } else {
        onClearHighlight?.();
      }
    }, isCollapsed ? 100 : 0);
    return () => clearTimeout(timer);
  }, [highlightedSourceId, isCollapsed, onClearHighlight]);

  return (
    <div
      className={`side-panel ${isCollapsed ? 'side-panel--collapsed' : ''} ${isDragOver ? 'side-panel--drag-over' : ''}`}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <div className="side-panel-header">
        <button
          className="side-panel-toggle"
          onClick={() => setIsCollapsed(!isCollapsed)}
          title={isCollapsed ? 'Expand panel' : 'Collapse panel'}
        >
          {isCollapsed ? '◀' : '▶'}
        </button>
        {!isCollapsed && (
          <div className="side-panel-tabs">
            <button
              className={`side-panel-tab ${activeTab === 'outline' ? 'side-panel-tab--active' : ''}`}
              onClick={() => setActiveTab('outline')}
            >
              Outline
            </button>
            <button
              className={`side-panel-tab ${activeTab === 'sources' ? 'side-panel-tab--active' : ''}`}
              onClick={() => setActiveTab('sources')}
            >
              Sources
              {sources.length > 0 && (
                <span className="side-panel-tab-count">{sources.length}</span>
              )}
            </button>
          </div>
        )}
      </div>

      {error && <div className="side-panel-error">{error}</div>}

      {!isCollapsed && (
        <div className="side-panel-content">
          {activeTab === 'outline' ? (
            <OutlineContent
              cells={outlineCells}
              focusedCellId={focusedCellId}
              onCellClick={onCellClick}
            />
          ) : (
            <SourcesContent
              sources={sources}
              isDragOver={isDragOver}
              pendingRemoval={pendingRemoval}
              onAddSource={handleAddSource}
              onRemoveSource={handleRemoveSource}
              onOpenSource={onSourceOpen}
              sourceRefs={sourceRefs}
            />
          )}
        </div>
      )}
    </div>
  );
}

// Outline tab content
interface OutlineContentProps {
  cells: Cell[];
  focusedCellId: string | null;
  onCellClick: (cellId: string) => void;
}

function OutlineContent({ cells, focusedCellId, onCellClick }: OutlineContentProps) {
  const itemRefs = useRef<Map<string, HTMLButtonElement>>(new Map());
  const scrollTimeoutRef = useRef<number | null>(null);

  // Scroll focused cell into view (debounced to avoid scroll jank during rapid navigation)
  useEffect(() => {
    if (!focusedCellId) return;

    // Clear any pending scroll
    if (scrollTimeoutRef.current !== null) {
      window.clearTimeout(scrollTimeoutRef.current);
    }

    // Debounce: wait for focus to settle before scrolling
    scrollTimeoutRef.current = window.setTimeout(() => {
      scrollTimeoutRef.current = null;
      const el = itemRefs.current.get(focusedCellId);
      if (el) {
        // Only scroll if element is not already visible
        const rect = el.getBoundingClientRect();
        const container = el.closest('.side-panel-list');
        if (container) {
          const containerRect = container.getBoundingClientRect();
          const isVisible = rect.top >= containerRect.top && rect.bottom <= containerRect.bottom;
          if (!isVisible) {
            el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
          }
        }
      }
    }, 150);

    return () => {
      if (scrollTimeoutRef.current !== null) {
        window.clearTimeout(scrollTimeoutRef.current);
      }
    };
  }, [focusedCellId]);

  if (cells.length === 0) {
    return <p className="side-panel-empty">No content yet</p>;
  }

  return (
    <div className="side-panel-list">
      {cells.map((cell) => (
        <OutlineItem
          key={cell.id}
          cell={cell}
          isActive={cell.id === focusedCellId}
          onClick={() => onCellClick(cell.id)}
          ref={(el) => {
            if (el) itemRefs.current.set(cell.id, el);
            else itemRefs.current.delete(cell.id);
          }}
        />
      ))}
    </div>
  );
}

interface OutlineItemProps {
  cell: Cell;
  isActive: boolean;
  onClick: () => void;
}

const OutlineItem = forwardRef<HTMLButtonElement, OutlineItemProps>(
  function OutlineItem({ cell, isActive, onClick }, ref) {
    const icon = getCellIcon(cell.type);
    const title = useMemo(() => getCellTitle(cell), [cell]);
    const isLive = cell.processingConfig?.refreshTrigger === 'onStreamOpen';
    const hasDependencies = cell.processingConfig?.refreshTrigger === 'onDependencyChange';

    return (
      <button
        ref={ref}
        className={`side-panel-item side-panel-item--outline ${isActive ? 'side-panel-item--active' : ''}`}
        onClick={onClick}
        title={title}
      >
        <span className="side-panel-item-icon">{icon}</span>
        <span className="side-panel-item-text">{title}</span>
        {(isLive || hasDependencies) && (
          <span className="side-panel-item-badges">
            {isLive && <span className="side-panel-badge" title="Live block">⚡</span>}
            {hasDependencies && <span className="side-panel-badge" title="Has dependencies">🔗</span>}
          </span>
        )}
      </button>
    );
  }
);

// Sources tab content
interface SourcesContentProps {
  sources: SourceReference[];
  isDragOver: boolean;
  pendingRemoval: string | null;
  onAddSource: () => void;
  onRemoveSource: (id: string) => void;
  onOpenSource?: (source: SourceReference) => void;
  sourceRefs: React.MutableRefObject<Map<string, HTMLDivElement>>;
}

function SourcesContent({
  sources,
  isDragOver,
  pendingRemoval,
  onAddSource,
  onRemoveSource,
  onOpenSource,
  sourceRefs,
}: SourcesContentProps) {
  return (
    <>
      <div className="side-panel-actions">
        <button onClick={onAddSource} className="side-panel-add-btn">
          + Add Source
        </button>
      </div>
      <div className="side-panel-list">
        {isDragOver && (
          <div className="side-panel-drop-zone">Drop files here</div>
        )}
        {sources.length === 0 && !isDragOver ? (
          <p className="side-panel-empty">
            No sources attached
            <span className="side-panel-empty-hint">Drag files here or click Add</span>
          </p>
        ) : (
          sources.map((source) => (
            <SourceItem
              key={source.id}
              source={source}
              isRemoving={pendingRemoval === source.id}
              onRemove={() => onRemoveSource(source.id)}
              onOpen={() => onOpenSource?.(source)}
              ref={(el) => {
                if (el) sourceRefs.current.set(source.id, el);
                else sourceRefs.current.delete(source.id);
              }}
            />
          ))
        )}
      </div>
    </>
  );
}

interface SourceItemProps {
  source: SourceReference;
  isRemoving: boolean;
  onRemove: () => void;
  onOpen: () => void;
}

const SourceItem = forwardRef<HTMLDivElement, SourceItemProps>(
  function SourceItem({ source, isRemoving, onRemove, onOpen }, ref) {
    const icon = getFileIcon(source.fileType);
    const embeddingInfo = getEmbeddingInfo(source.embeddingStatus);

    return (
      <div
        ref={ref}
        className={`side-panel-item side-panel-item--source ${isRemoving ? 'side-panel-item--removing' : ''}`}
        onClick={onOpen}
        title={`Open ${source.displayName}`}
        role="button"
        tabIndex={0}
        onKeyDown={(event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            onOpen();
          }
        }}
      >
        <span className="side-panel-item-icon">{icon}</span>
        <div className="side-panel-item-info">
          <span className="side-panel-item-text">{source.displayName}</span>
          <div className="side-panel-item-meta">
            {source.pageCount && (
              <span>{source.pageCount} pages</span>
            )}
            {embeddingInfo && (
              <span
                className={`side-panel-embedding side-panel-embedding--${source.embeddingStatus}`}
                title={embeddingInfo.tooltip}
              >
                {embeddingInfo.label}
              </span>
            )}
          </div>
        </div>
        <button
          className="side-panel-item-remove"
          onClick={(e) => {
            e.stopPropagation();
            onRemove();
          }}
          title="Remove source"
          disabled={isRemoving}
        >
          {isRemoving ? '…' : '×'}
        </button>
      </div>
    );
  }
);

// Helper functions
function getCellIcon(type: CellType): string {
  switch (type) {
    case 'text': return 'T';
    case 'aiResponse': return '✦';
    case 'quote': return '"';
    default: return '•';
  }
}

function getCellTitle(cell: Cell): string {
  return truncate(deriveCellTitle(cell), 50);
}

function stripHtml(html: string): string {
  const tmp = document.createElement('div');
  tmp.innerHTML = html;
  return tmp.textContent || tmp.innerText || '';
}

function truncate(text: string, maxLength: number): string {
  const trimmed = text.trim().replace(/\s+/g, ' ');
  if (trimmed.length <= maxLength) return trimmed;
  return trimmed.slice(0, maxLength - 1) + '…';
}

function getFileIcon(fileType: string): string {
  switch (fileType) {
    case 'pdf': return '📄';
    case 'text':
    case 'markdown': return '📝';
    case 'image': return '🖼';
    default: return '📎';
  }
}

function getEmbeddingInfo(status: string): { label: string; tooltip: string } | null {
  switch (status) {
    case 'processing':
      return { label: 'Indexing…', tooltip: 'Creating semantic index for AI search' };
    case 'complete':
      return { label: 'Indexed', tooltip: 'Ready for semantic search' };
    case 'failed':
      return { label: 'Index failed', tooltip: 'Semantic indexing failed - full text will be used' };
    case 'unconfigured':
      return { label: 'Not indexed', tooltip: 'Semantic search is not available in this version' };
    default:
      return null;
  }
}
