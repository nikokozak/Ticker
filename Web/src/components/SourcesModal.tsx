import { useCallback, useEffect, useRef, useState, forwardRef, type ReactNode } from 'react';
import type { SourceIndexStatus, SourceReference } from '../types';
import { bridge } from '../types';
import { DocumentIcon, ImageIcon, PaperclipIcon, XIcon } from './icons';

interface SourceIndexStatusLineInput {
  status: SourceIndexStatus;
  progress?: number | null;
  pageCount?: number | null;
  aiExcluded?: boolean;
}

export function formatSourceIndexStatusLine({
  status,
  progress,
  pageCount,
  aiExcluded = false,
}: SourceIndexStatusLineInput): string | null {
  let line: string | null;

  switch (status) {
    case 'indexing':
      if (typeof progress === 'number' && Number.isFinite(progress)) {
        const percent = Math.round(Math.min(1, Math.max(0, progress)) * 100);
        line = `indexing · ${percent}%`;
      } else {
        line = 'indexing…';
      }
      break;
    case 'ready': {
      const pages = formatPageCount(pageCount ?? null);
      line = pages && pageCount && pageCount > 0 ? `${pages} · indexed` : pages;
      break;
    }
    case 'failed_no_text':
      line = 'No readable text — this looks like a scanned document';
      break;
    case 'failed':
      line = 'Indexing failed';
      break;
    case 'pending':
      line = 'waiting to index…';
      break;
    default:
      line = null;
  }

  if (!aiExcluded) return line;
  return line ? `${line} · private` : 'private';
}

function canRetryIndexing(status: SourceIndexStatus): boolean {
  return status === 'failed_no_text' || status === 'failed';
}

interface SourceIndexStatusSnapshot {
  status: SourceIndexStatus;
  progress?: number | null;
}

interface SourcesModalProps {
  isOpen: boolean;
  streamId: string;
  sources: SourceReference[];
  onClose: () => void;
  onSourceRemoved: (sourceId: string) => void;
  onSourceAIExclusionChanged: (sourceId: string, excluded: boolean) => void;
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
  onSourceAIExclusionChanged,
  onSourceOpen,
  highlightedSourceId,
  onClearHighlight,
}: SourcesModalProps) {
  const [error, setError] = useState<string | null>(null);
  const [pendingRemoval, setPendingRemoval] = useState<string | null>(null);
  const [isDragOver, setIsDragOver] = useState(false);
  const [indexUpdates, setIndexUpdates] = useState<Record<string, SourceIndexStatusSnapshot>>({});
  const sourceRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const errorTimerRef = useRef<number>();
  const highlightClearTimerRef = useRef<number>();

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

  const handleRetryIndexing = (sourceId: string) => {
    setError(null);
    setIndexUpdates((previous) => ({
      ...previous,
      [sourceId]: { status: 'pending' },
    }));
    bridge.send({ type: 'retrySourceIndexing', payload: { sourceId } });
  };

  const handleToggleAIExclusion = (sourceId: string, excluded: boolean) => {
    setError(null);
    onSourceAIExclusionChanged(sourceId, excluded);
    bridge.send({ type: 'setSourceAIExclusion', payload: { sourceId, excluded } });
  };

  const handleOpenSource = (source: SourceReference) => {
    onSourceOpen?.(source);
    handleClose();
  };

  const showError = (message: string) => {
    setError(message);
    window.clearTimeout(errorTimerRef.current);
    errorTimerRef.current = window.setTimeout(() => setError(null), 5000);
  };

  useEffect(() => () => {
    window.clearTimeout(errorTimerRef.current);
    window.clearTimeout(highlightClearTimerRef.current);
  }, []);

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
      if (message.type === 'sourceIndexStatusChanged' && message.payload?.sourceId) {
        const sourceId = message.payload.sourceId as string;
        const status = message.payload.status as SourceIndexStatus | undefined;
        if (!status) return;
        const progress = typeof message.payload.progress === 'number'
          ? message.payload.progress
          : undefined;
        setIndexUpdates((previous) => ({
          ...previous,
          [sourceId]: { status, progress },
        }));
      }
    });
    return unsubscribe;
  }, [isOpen, onSourceRemoved]);

  useEffect(() => {
    if (!isOpen) {
      setIndexUpdates({});
      return;
    }

    const sourceIds = new Set(sources.map((source) => source.id));
    setIndexUpdates((previous) => {
      const next = Object.fromEntries(
        Object.entries(previous).filter(([sourceId]) => sourceIds.has(sourceId))
      );
      return Object.keys(next).length === Object.keys(previous).length ? previous : next;
    });
  }, [isOpen, sources]);

  useEffect(() => {
    if (!isOpen || !highlightedSourceId) return undefined;

    const timer = window.setTimeout(() => {
      const sourceEl = sourceRefs.current.get(highlightedSourceId);
      if (sourceEl) {
        sourceEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
        sourceEl.classList.add('sources-modal-item--highlighted');
        highlightClearTimerRef.current = window.setTimeout(() => {
          sourceEl.classList.remove('sources-modal-item--highlighted');
          onClearHighlight?.();
        }, 2000);
      } else {
        onClearHighlight?.();
      }
    }, 80);
    return () => {
      window.clearTimeout(timer);
      window.clearTimeout(highlightClearTimerRef.current);
    };
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
            <XIcon size={16} />
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
                indexStatus={indexUpdates[source.id]}
                isRemoving={pendingRemoval === source.id}
                onRemove={() => handleRemoveSource(source.id)}
                onRetryIndexing={() => handleRetryIndexing(source.id)}
                onToggleAIExclusion={() => handleToggleAIExclusion(source.id, !source.aiExcluded)}
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
  indexStatus?: SourceIndexStatusSnapshot;
  isRemoving: boolean;
  onRemove: () => void;
  onRetryIndexing: () => void;
  onToggleAIExclusion: () => void;
  onOpen: () => void;
}

const SourceItem = forwardRef<HTMLDivElement, SourceItemProps>(
  function SourceItem({
    source,
    indexStatus,
    isRemoving,
    onRemove,
    onRetryIndexing,
    onToggleAIExclusion,
    onOpen,
  }, ref) {
    const icon = getFileIcon(source.fileType);
    const currentStatus = indexStatus?.status ?? source.indexStatus;
    const statusLine = formatSourceIndexStatusLine({
      status: currentStatus,
      progress: indexStatus?.progress,
      pageCount: source.pageCount,
      aiExcluded: source.aiExcluded,
    });
    const showsRetry = canRetryIndexing(currentStatus);
    const title = source.shortTitle || source.displayName;
    const showFullName = source.displayName !== title;

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
          <span className="sources-modal-item-name">{title}</span>
          {showFullName && (
            <span className="sources-modal-item-full-name">{source.displayName}</span>
          )}
          <div className="sources-modal-item-meta" aria-live="polite">
            {statusLine && <span>{statusLine}</span>}
            {showsRetry && (
              <button
                type="button"
                className="sources-modal-retry"
                onClick={(event) => {
                  event.stopPropagation();
                  onRetryIndexing();
                }}
              >
                Retry
              </button>
            )}
            <button
              type="button"
              className={[
                'sources-modal-private-toggle',
                source.aiExcluded ? 'sources-modal-private-toggle--active' : '',
              ].join(' ')}
              aria-pressed={source.aiExcluded}
              title="Private: never sent to AI. Stays on this device."
              onClick={(event) => {
                event.stopPropagation();
                onToggleAIExclusion();
              }}
            >
              Private
            </button>
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
          {isRemoving ? '…' : <XIcon size={14} />}
        </button>
      </div>
    );
  }
);

function getFileIcon(fileType: string): ReactNode {
  switch (fileType) {
    case 'pdf': return <DocumentIcon size={14} />;
    case 'text':
    case 'markdown': return <DocumentIcon size={14} />;
    case 'image': return <ImageIcon size={14} />;
    default: return <PaperclipIcon size={14} />;
  }
}

function formatPageCount(pageCount: number | null): string | null {
  if (pageCount === null) return null;
  return `${pageCount} ${pageCount === 1 ? 'page' : 'pages'}`;
}
