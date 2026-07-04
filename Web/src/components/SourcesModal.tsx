import { useCallback, useEffect, useRef, useState, forwardRef } from 'react';
import { SourceReference, bridge } from '../types';

interface SourcesModalProps {
  isOpen: boolean;
  streamId: string;
  sources: SourceReference[];
  onClose: () => void;
  onSourceRemoved: (sourceId: string) => void;
  onSourceOpen?: (source: SourceReference) => void;
  highlightedSourceId?: string | null;
  onClearHighlight?: () => void;
}

export function SourcesModal({
  isOpen,
  streamId,
  sources,
  onClose,
  onSourceRemoved,
  onSourceOpen,
  highlightedSourceId,
  onClearHighlight,
}: SourcesModalProps) {
  const [error, setError] = useState<string | null>(null);
  const [pendingRemoval, setPendingRemoval] = useState<string | null>(null);
  const [isDragOver, setIsDragOver] = useState(false);
  const sourceRefs = useRef<Map<string, HTMLDivElement>>(new Map());

  const handleClose = useCallback(() => {
    setError(null);
    setIsDragOver(false);
    onClose();
  }, [onClose]);

  const handleAddSource = () => {
    setError(null);
    bridge.send({ type: 'addSource', payload: { streamId } });
  };

  const handleRemoveSource = (id: string) => {
    setError(null);
    setPendingRemoval(id);
    bridge.send({ type: 'removeSource', payload: { id } });
  };

  const handleOpenSource = (source: SourceReference) => {
    onSourceOpen?.(source);
    handleClose();
  };

  const showError = (message: string) => {
    setError(message);
    window.setTimeout(() => setError(null), 5000);
  };

  const handleDragOver = useCallback((event: React.DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    if (event.dataTransfer.types.includes('Files')) {
      event.dataTransfer.dropEffect = 'copy';
      setIsDragOver(true);
    }
  }, []);

  const handleDragLeave = useCallback((event: React.DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX;
    const y = event.clientY;
    if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) {
      setIsDragOver(false);
    }
  }, []);

  const handleDrop = useCallback((event: React.DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    setIsDragOver(false);
  }, []);

  useEffect(() => {
    if (!isOpen) return undefined;

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        handleClose();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleClose, isOpen]);

  useEffect(() => {
    if (!isOpen) return undefined;

    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'sourceError' && message.payload?.error) {
        showError(message.payload.error as string);
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
  }, [isOpen, onSourceRemoved]);

  useEffect(() => {
    if (!isOpen || !highlightedSourceId) return undefined;

    const timer = window.setTimeout(() => {
      const sourceEl = sourceRefs.current.get(highlightedSourceId);
      if (sourceEl) {
        sourceEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
        sourceEl.classList.add('sources-modal-item--highlighted');
        window.setTimeout(() => {
          sourceEl.classList.remove('sources-modal-item--highlighted');
          onClearHighlight?.();
        }, 2000);
      } else {
        onClearHighlight?.();
      }
    }, 80);
    return () => window.clearTimeout(timer);
  }, [highlightedSourceId, isOpen, onClearHighlight]);

  if (!isOpen) return null;

  return (
    <div className="sources-modal-overlay" onClick={handleClose}>
      <div
        className={`sources-modal ${isDragOver ? 'sources-modal--drag-over' : ''}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby="sources-modal-title"
        onClick={(event) => event.stopPropagation()}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
      >
        <div className="sources-modal-header">
          <div>
            <h2 id="sources-modal-title">Sources</h2>
            <p>{sources.length} {sources.length === 1 ? 'source' : 'sources'}</p>
          </div>
          <button
            type="button"
            className="sources-modal-close"
            onClick={handleClose}
            aria-label="Close sources"
            title="Close"
          >
            ×
          </button>
        </div>

        {error && <div className="sources-modal-error">{error}</div>}

        <button type="button" onClick={handleAddSource} className="sources-modal-add">
          + Add Source
        </button>

        <div className="sources-modal-list">
          {isDragOver && (
            <div className="sources-modal-drop-zone">Drop files here</div>
          )}
          {sources.length === 0 && !isDragOver ? (
            <p className="sources-modal-empty">
              No sources attached
              <span>Drag files here or click Add Source.</span>
            </p>
          ) : (
            sources.map((source) => (
              <SourceItem
                key={source.id}
                source={source}
                isRemoving={pendingRemoval === source.id}
                onRemove={() => handleRemoveSource(source.id)}
                onOpen={() => handleOpenSource(source)}
                ref={(el) => {
                  if (el) sourceRefs.current.set(source.id, el);
                  else sourceRefs.current.delete(source.id);
                }}
              />
            ))
          )}
        </div>
      </div>
    </div>
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
    const pageCount = formatPageCount(source.pageCount);

    return (
      <div
        ref={ref}
        className={`sources-modal-item ${isRemoving ? 'sources-modal-item--removing' : ''}`}
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
        <span className="sources-modal-item-icon">{icon}</span>
        <div className="sources-modal-item-info">
          <span className="sources-modal-item-name">{source.displayName}</span>
          <div className="sources-modal-item-meta">
            {pageCount && <span>{pageCount}</span>}
            {embeddingInfo && (
              <span
                className={`sources-modal-embedding sources-modal-embedding--${source.embeddingStatus}`}
                title={embeddingInfo.tooltip}
              >
                {embeddingInfo.label}
              </span>
            )}
          </div>
        </div>
        <button
          type="button"
          className="sources-modal-remove"
          onClick={(event) => {
            event.stopPropagation();
            onRemove();
          }}
          title={`Remove ${source.displayName}`}
          aria-label={`Remove ${source.displayName}`}
          disabled={isRemoving}
        >
          {isRemoving ? '…' : '×'}
        </button>
      </div>
    );
  }
);

function getFileIcon(fileType: string): string {
  switch (fileType) {
    case 'pdf': return '📄';
    case 'text':
    case 'markdown': return '📝';
    case 'image': return '🖼';
    default: return '📎';
  }
}

function formatPageCount(pageCount: number | null): string | null {
  if (pageCount === null) return null;
  return `${pageCount} ${pageCount === 1 ? 'page' : 'pages'}`;
}

function getEmbeddingInfo(status: string): { label: string; tooltip: string } | null {
  switch (status) {
    case 'processing':
      return { label: 'Indexing…', tooltip: 'Creating semantic index for AI search' };
    case 'complete':
      return { label: 'Indexed', tooltip: 'Ready for semantic search' };
    case 'failed':
      return { label: 'Index failed', tooltip: 'Semantic indexing failed - full text will be used' };
    default:
      return null;
  }
}
