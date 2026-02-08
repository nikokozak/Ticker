import type { Cell } from '../types/models';
import { extractFirstHeadingFromHtml } from './cellTitle';

/**
 * Shared filter for @reference suggestion candidates.
 * Keeps legacy and unified editors in sync to avoid drift.
 */
export function filterReferenceSuggestionCells(
  cells: Cell[],
  currentCellId?: string | null
): Cell[] {
  return cells.filter((cell) => {
    // Exclude the currently edited cell to avoid self-references.
    if (currentCellId && cell.id === currentCellId) return false;

    // Always include AI responses, even when rich content looks empty as plain text.
    if (cell.type === 'aiResponse') return true;

    // Always include cells with explicit names or heading-derived titles.
    if (cell.blockName || extractFirstHeadingFromHtml(cell.content)) return true;

    // Exclude empty spacing cells.
    const textContent = cell.content.replace(/<[^>]*>/g, '').trim();
    return textContent.length > 0;
  });
}
