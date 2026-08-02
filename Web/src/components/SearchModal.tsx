import { useState, useEffect, useRef, useCallback, type ReactNode } from 'react';
import { SearchResult, HybridSearchResults, bridge } from '../types';
import { DocumentIcon, SearchIcon, Spinner } from './icons';
import { markdownPreviewLine, plainTextFromMarkdown } from '../utils/markdownPreview';
import { Modal } from './Modal';

interface SearchModalProps {
  isOpen: boolean;
  onClose: () => void;
  currentStreamId: string | null;
  isStreamOpen: boolean;
  /** Scroll the open editor to the first occurrence of the matched text */
  onNavigateToMatch: (matchText: string) => void;
  /** Navigate to another stream, to a text match or a source */
  onNavigateToStream: (streamId: string, targetId: string, targetType?: 'match' | 'source') => void;
  /** Navigate to a source in the source panel (for chunk results) */
  onNavigateToSource: (sourceId: string) => void;
}

export function SearchModal({
  isOpen,
  onClose,
  currentStreamId,
  isStreamOpen,
  onNavigateToMatch,
  onNavigateToStream,
  onNavigateToSource,
}: SearchModalProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<HybridSearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [expandedResult, setExpandedResult] = useState<SearchResult | null>(null);

  const debounceRef = useRef<number>();
  // Sequence counter to discard stale responses from out-of-order requests
  const requestSequenceRef = useRef(0);

  // Reset state when opening and invalidate in-flight requests when closing.
  useEffect(() => {
    if (isOpen) {
      setQuery('');
      setResults(null);
      setSelectedIndex(0);
      setExpandedResult(null);
      setError(null);
      setLoading(false);
      requestSequenceRef.current = 0;
    } else {
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

    debounceRef.current = window.setTimeout(async () => {
      try {
        const response = await bridge.sendAsync<HybridSearchResults>('hybridSearch', {
          query: query.trim(),
          // Absent when searching from the stream list
          ...(currentStreamId ? { currentStreamId } : {}),
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
    onClose();
    if (result.sourceType === 'chunk' && result.sourceId) {
      onNavigateToStream(result.streamId, result.sourceId, 'source');
    } else {
      // Document result: scroll the target stream to the matched text
      onNavigateToStream(result.streamId, query.trim(), 'match');
    }
  }, [onClose, onNavigateToStream, query]);

  const handleResultClick = useCallback((result: SearchResult) => {
    if (isStreamOpen && result.streamId === currentStreamId) {
      // Current stream
      onClose();
      if (result.sourceType === 'chunk' && result.sourceId) {
        // Chunk result: navigate to source in source panel
        onNavigateToSource(result.sourceId);
      } else {
        // Document result: scroll to the matched text
        onNavigateToMatch(query.trim());
      }
    } else if (!isStreamOpen) {
      navigateToResult(result);
    } else {
      // Other stream: show expanded preview
      setExpandedResult(result);
    }
  }, [currentStreamId, isStreamOpen, navigateToResult, onClose, onNavigateToMatch, onNavigateToSource, query]);

  // Keyboard navigation
  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
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
    <Modal
      className="search-modal"
      aria-label="Search streams and sources"
      onRequestClose={() => expandedResult ? setExpandedResult(null) : onClose()}
      onKeyDown={handleKeyDown}
    >
        <div className="search-modal-input-wrapper">
          <span className="search-modal-icon"><SearchIcon size={16} /></span>
          <input
            type="text"
            className="search-modal-input"
            placeholder="Search…"
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
              <span className="search-modal-preview-stream">{plainTextFromMarkdown(expandedResult.streamTitle)}</span>
              <button
                className="search-modal-preview-close"
                onClick={() => setExpandedResult(null)}
              >
                ← Back
              </button>
            </div>
            <div className="search-modal-preview-title">{plainTextFromMarkdown(expandedResult.title)}</div>
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
                  {isStreamOpen ? 'Other Streams' : 'Streams'}
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
              <div className="search-modal-empty">No results for “{query.trim()}”</div>
            )}
          </div>
        )}

        {!results && !loading && query.trim() === '' && (
          <div className="search-modal-hint">
            Type to search streams and sources
          </div>
        )}
    </Modal>
  );
}

interface SearchResultItemProps {
  result: SearchResult;
  isSelected: boolean;
  onClick: () => void;
}

function SearchResultItem({ result, isSelected, onClick }: SearchResultItemProps) {
  const icon = getResultIcon(result);
  const title = plainTextFromMarkdown(result.sourceType === 'chunk'
    ? result.shortTitle ?? result.title
    : result.title);
  const fullTitle = plainTextFromMarkdown(result.sourceType === 'chunk'
    ? result.sourceName ?? result.title
    : result.title);
  const streamTitle = plainTextFromMarkdown(result.streamTitle);

  return (
    <button
      className={`search-result-item ${isSelected ? 'search-result-item--selected' : ''}`}
      onClick={onClick}
      title={fullTitle}
    >
      <span className="search-result-icon">{icon}</span>
      <div className="search-result-content">
        <div className="search-result-title">
          {streamTitle !== '' && result.sourceType === 'document' && (
            <span className="search-result-stream">[{streamTitle}]</span>
          )}
          {title}
        </div>
        <div className="search-result-snippet">{markdownPreviewLine(result.snippet)}</div>
      </div>
    </button>
  );
}

function getResultIcon(result: SearchResult): ReactNode {
  if (result.sourceType === 'chunk') {
    return <DocumentIcon size={14} />;
  }
  return 'T';
}
