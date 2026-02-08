export const INTERNAL_CELL_DRAG_MIME = 'application/x-ticker-cell-drag';
export const INTERNAL_CELL_DRAG_TEXT = 'ticker-cell-drag';

export function hasInternalCellDragType(dataTransfer: DataTransfer | null | undefined): boolean {
  if (!dataTransfer) return false;
  return Array.from(dataTransfer.types).includes(INTERNAL_CELL_DRAG_MIME);
}
