import { useState, useEffect, useRef, useCallback } from 'react';
import { useBlockStore } from '../store/blockStore';
import { findByShortIdOrName } from '../utils/references';
import { deriveCellTitle } from '../utils/cellTitle';

interface ReferencePreviewProps {
  onScrollToCell?: (cellId: string) => void;
}

interface PreviewState {
  visible: boolean;
  content: string;
  title: string;
  cellId: string;
  x: number;
  y: number;
  position: 'above' | 'below';
}

/**
 * Global reference preview tooltip that appears on hover over @block-xxx references.
 * Attaches to document and listens for mouseenter/mouseleave on .cell-reference elements.
 */
export function ReferencePreview({ onScrollToCell }: ReferencePreviewProps) {
  const [preview, setPreview] = useState<PreviewState>({
    visible: false,
    content: '',
    title: '',
    cellId: '',
    x: 0,
    y: 0,
    position: 'below',
  });

  const hideTimeoutRef = useRef<number | null>(null);
  const previewRef = useRef<HTMLDivElement>(null);

  const showPreview = useCallback((refId: string, rect: DOMRect) => {
    // Clear any pending hide
    if (hideTimeoutRef.current) {
      clearTimeout(hideTimeoutRef.current);
      hideTimeoutRef.current = null;
    }

    const blocks = useBlockStore.getState().blocks;
    const cell = findByShortIdOrName(blocks, refId);

    if (cell) {
      // Strip HTML and get first ~150 chars
      const plainText = cell.content
        .replace(/<[^>]*>/g, '')
        .replace(/\s+/g, ' ')
        .trim();
      const previewContent = plainText.length > 150
        ? plainText.slice(0, 150) + '...'
        : plainText;

      const title = deriveCellTitle(cell);

      // Estimate preview height (~120px for typical content)
      const estimatedHeight = 120;
      const gap = 6;
      const viewportHeight = window.innerHeight;

      // Check if there's enough space below
      const spaceBelow = viewportHeight - rect.bottom;
      const spaceAbove = rect.top;

      // Position above if not enough space below and more space above
      const position: 'above' | 'below' =
        spaceBelow < estimatedHeight && spaceAbove > spaceBelow ? 'above' : 'below';

      // Calculate x position, ensuring it doesn't go off-screen
      const previewWidth = 320; // max-width from CSS
      let x = rect.left;
      if (x + previewWidth > window.innerWidth - 16) {
        x = window.innerWidth - previewWidth - 16;
      }
      if (x < 16) {
        x = 16;
      }

      setPreview({
        visible: true,
        content: previewContent,
        title,
        cellId: cell.id,
        x,
        y: position === 'below' ? rect.bottom + gap : rect.top - gap,
        position,
      });
    }
  }, []);

  const hidePreview = useCallback(() => {
    // Delay hiding to allow mouse to move to preview
    hideTimeoutRef.current = window.setTimeout(() => {
      setPreview(prev => ({ ...prev, visible: false }));
    }, 150);
  }, []);

  const handleClick = useCallback(() => {
    if (preview.cellId && onScrollToCell) {
      onScrollToCell(preview.cellId);
      setPreview(prev => ({ ...prev, visible: false }));
    }
  }, [preview.cellId, onScrollToCell]);

  // Keep preview visible when hovering over it
  const handlePreviewMouseEnter = useCallback(() => {
    if (hideTimeoutRef.current) {
      clearTimeout(hideTimeoutRef.current);
      hideTimeoutRef.current = null;
    }
  }, []);

  const handlePreviewMouseLeave = useCallback(() => {
    hidePreview();
  }, [hidePreview]);

  useEffect(() => {
    const handleMouseEnter = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (target.classList.contains('cell-reference')) {
        const refId = target.getAttribute('data-id');
        if (refId) {
          const rect = target.getBoundingClientRect();
          showPreview(refId, rect);
        }
      }
    };

    const handleMouseLeave = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (target.classList.contains('cell-reference')) {
        hidePreview();
      }
    };

    // Use event delegation on document
    document.addEventListener('mouseenter', handleMouseEnter, true);
    document.addEventListener('mouseleave', handleMouseLeave, true);

    return () => {
      document.removeEventListener('mouseenter', handleMouseEnter, true);
      document.removeEventListener('mouseleave', handleMouseLeave, true);
      if (hideTimeoutRef.current) {
        clearTimeout(hideTimeoutRef.current);
      }
    };
  }, [showPreview, hidePreview]);

  if (!preview.visible) return null;

  return (
    <div
      ref={previewRef}
      className={`reference-preview reference-preview--${preview.position}`}
      style={{
        left: preview.x,
        top: preview.y,
        // When above, translate up by full height so bottom aligns with y
        transform: preview.position === 'above' ? 'translateY(-100%)' : undefined,
      }}
      onClick={handleClick}
      onMouseEnter={handlePreviewMouseEnter}
      onMouseLeave={handlePreviewMouseLeave}
    >
      <div className="reference-preview-title">{preview.title}</div>
      <div className="reference-preview-content">{preview.content}</div>
      <div className="reference-preview-hint">Click to navigate</div>
    </div>
  );
}
