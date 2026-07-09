import { useState, useEffect, useRef, useCallback, type ReactNode } from 'react';
import { SearchResult, HybridSearchResults, bridge } from '../types';
import { DocumentIcon, SearchIcon, SparkleIcon, Spinner } from './icons';
import { markdownPreviewLine } from '../utils/markdownPreview';

interface SearchModalProps {
  isOpen: boolean;
  onClose: () => void;
  currentStreamId: string | null;
  isStreamOpen: boolean;
  onNavigateToCell: (cellId: string) => void;
  /** Navigate to another stream, optionally to a specific cell or source */
  onNavigateToStream: (streamId: string, targetId: string, targetType?: 'cell' | 'source') => void;
  /** Navigate to a source in the source panel (for chunk results) */
  onNavigateToSource: (sourceId: string) => void;
}

export function SearchModal({
  isOpen,
  onClose,
  currentStreamId,
  isStreamOpen,
  onNavigateToCell,
  onNavigateToStream,
  onNavigateToSource,
}: SearchModalProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<HybridSearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [expandedResult, setExpandedResult] = useState<SearchResult | null>(null);

  const inputRef = useRef<HTMLInputElement>(null);
  const debounceRef = useRef<number>();
  // Sequence counter to discard stale responses from out-of-order requests
  const requestSequenceRef = useRef(0);

  // Focus input when modal opens, invalidate in-flight requests when closing
  useEffect(() => {
    if (isOpen) {
      setQuery('');
      setResults(null);
      setSelectedIndex(0);
      setExpandedResult(null);
      setError(null);
      setLoading(false);
      requestSequenceRef.current = 0;
      setTimeout(() => inputRef.current?.focus(), 50);
    } else {
      // Modal closing - increment sequence to invalidate any in-flight requests
      requestSequenceRef.current++;
    }
  }, [isOpen]);

  // Debounced search with sequence tracking to handle out-of-order responses
  useEffect(() => {
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

    if (!query.trim()) {
      // Increment sequence to invalidate any in-flight requests
      requestSequenceRef.current++;
      setResults(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    // Increment sequence for this request
    const currentSequence = ++requestSequenceRef.current;

    if (!currentStreamId) {
      setResults({ currentStreamResults: [], otherStreamResults: [] });
      setLoading(false);
      return;
    }

    debounceRef.current = window.setTimeout(async () => {
      try {
        const response = await bridge.sendAsync<HybridSearchResults>('hybridSearch', {
          query: query.trim(),
          currentStreamId,
          limit: 20,
        });
        // Only update state if this is still the most recent request
        if (currentSequence === requestSequenceRef.current) {
          setResults(response);
          setError(null);
          setSelectedIndex(0);
        }
      } catch (err) {
        // Only update error state if this is still the most recent request
        if (currentSequence === requestSequenceRef.current) {
          setError(err instanceof Error ? err.message : 'Search failed');
          setResults(null);
        }
      } finally {
        // Only clear loading if this is still the most recent request
        if (currentSequence === requestSequenceRef.current) {
          setLoading(false);
        }
      }
    }, 200);

    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }
    };
  }, [query, currentStreamId]);

  // Get all results as flat array for navigation
  const allResults = results
    ? [...results.currentStreamResults, ...results.otherStreamResults]
    : [];

  // Handle clicking on a search result
  const navigateToResult = useCallback((result: SearchResult) => {
    const targetId = result.sourceType === 'chunk' && result.sourceId
      ? result.sourceId
      : result.id;
    const targetType = result.sourceType === 'chunk' ? 'source' : 'cell';
    onClose();
    onNavigateToStream(result.streamId, targetId, targetType);
  }, [onClose, onNavigateToStream]);

  const handleResultClick = useCallback((result: SearchResult) => {
    if (isStreamOpen && result.streamId === currentStreamId) {
      // Current stream
      onClose();
      if (result.sourceType === 'chunk' && result.sourceId) {
        // Chunk result: navigate to source in source panel
        onNavigateToSource(result.sourceId);
      } else {
        // Cell result: scroll to cell
        onNavigateToCell(result.id);
      }
    } else if (!isStreamOpen) {
      navigateToResult(result);
    } else {
      // Other stream: show expanded preview
      setExpandedResult(result);
    }
  }, [currentStreamId, isStreamOpen, navigateToResult, onClose, onNavigateToCell, onNavigateToSource]);

  // Keyboard navigation
  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      if (expandedResult) {
        setExpandedResult(null);
      } else {
        onClose();
      }
      return;
    }

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, allResults.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === 'Enter' && allResults.length > 0) {
      e.preventDefault();
      const result = allResults[selectedIndex];
      handleResultClick(result);
    }
  }, [allResults, selectedIndex, expandedResult, onClose, handleResultClick]);

  const handleGoToStream = () => {
    if (expandedResult) {
      navigateToResult(expandedResult);
    }
  };

  if (!isOpen) return null;

  return (
    <div className="search-modal-overlay" onClick={onClose}>
      <div className="search-modal" onClick={(e) => e.stopPropagation()} onKeyDown={handleKeyDown}>
        <div className="search-modal-input-wrapper">
          <span className="search-modal-icon"><SearchIcon size={16} /></span>
          <input
            ref={inputRef}
            type="text"
            className="search-modal-input"
            placeholder="Search cells..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          {loading && <Spinner className="search-modal-spinner" />}
        </div>

        {error && (
          <div className="search-modal-error">{error}</div>
        )}

        {expandedResult ? (
          <div className="search-modal-preview">
            <div className="search-modal-preview-header">
              <span className="search-modal-preview-stream">{expandedResult.streamTitle}</span>
              <button
                className="search-modal-preview-close"
                onClick={() => setExpandedResult(null)}
              >
                ← Back
              </button>
            </div>
            <div className="search-modal-preview-title">{expandedResult.title}</div>
            <div className="search-modal-preview-content">{markdownPreviewLine(expandedResult.snippet)}</div>
            <button
              className="search-modal-go-button"
              onClick={handleGoToStream}
            >
              Go to stream →
            </button>
          </div>
        ) : results && (
          <div className="search-modal-results">
            {results.currentStreamResults.length > 0 && (
              <>
                <div className="search-modal-section-header">This Stream</div>
                {results.currentStreamResults.map((result, index) => (
                  <SearchResultItem
                    key={`${result.streamId}-${result.id}-${result.sourceType}`}
                    result={result}
                    isSelected={index === selectedIndex}
                    onClick={() => handleResultClick(result)}
                  />
                ))}
              </>
            )}

            {results.otherStreamResults.length > 0 && (
              <>
                <div className="search-modal-section-header search-modal-section-divider">
                  Other Streams
                </div>
                {results.otherStreamResults.map((result, index) => (
                  <SearchResultItem
                    key={`${result.streamId}-${result.id}-${result.sourceType}`}
                    result={result}
                    isSelected={index + results.currentStreamResults.length === selectedIndex}
                    onClick={() => handleResultClick(result)}
                  />
                ))}
              </>
            )}

            {results.currentStreamResults.length === 0 && results.otherStreamResults.length === 0 && (
              <div className="search-modal-empty">No results found</div>
            )}
          </div>
        )}

        {!results && !loading && query.trim() === '' && (
          <div className="search-modal-hint">
            Type to search across cells and sources
          </div>
        )}
      </div>
    </div>
  );
}

interface SearchResultItemProps {
  result: SearchResult;
  isSelected: boolean;
  onClick: () => void;
}

function SearchResultItem({ result, isSelected, onClick }: SearchResultItemProps) {
  const icon = getResultIcon(result);
  const badge = getMatchBadge(result.matchType);
  const title = result.sourceType === 'chunk'
    ? result.shortTitle ?? result.title
    : result.title;
  const fullTitle = result.sourceType === 'chunk'
    ? result.sourceName ?? result.title
    : result.title;

  return (
    <button
      className={`search-result-item ${isSelected ? 'search-result-item--selected' : ''}`}
      onClick={onClick}
      title={fullTitle}
    >
      <span className="search-result-icon">{icon}</span>
      <div className="search-result-content">
        <div className="search-result-title">
          {result.streamTitle !== '' && result.sourceType === 'cell' && (
            <span className="search-result-stream">[{result.streamTitle}]</span>
          )}
          {title}
        </div>
        <div className="search-result-snippet">{markdownPreviewLine(result.snippet)}</div>
      </div>
      {badge && <span className="search-result-badge">{badge}</span>}
    </button>
  );
}

function getResultIcon(result: SearchResult): ReactNode {
  if (result.sourceType === 'chunk') {
    return <DocumentIcon size={14} />;
  }
  switch (result.cellType) {
    case 'text':
      return 'T';
    case 'aiResponse':
      return <SparkleIcon size={14} />;
    case 'quote':
      return '"';
    default:
      return '•';
  }
}

function getMatchBadge(matchType: string): ReactNode | null {
  switch (matchType) {
    case 'semantic':
      return <SparkleIcon size={14} />;
    // Note: 'both' match type is reserved for future use when we can correlate
    // cell content with source chunks that share the same underlying text
    default:
      return null;
  }
}
