export interface SelectionMenuRect {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

export interface SelectionMenuSize {
  width: number;
  height: number;
}

export interface SelectionMenuPlacementInput {
  coords: SelectionMenuRect;
  shellRect: SelectionMenuRect;
  menuSize?: Partial<SelectionMenuSize>;
  viewportHeight: number;
  gap?: number;
  horizontalInset?: number;
}

export interface SelectionMenuPlacement {
  left: number;
  top: number;
}

export const DEFAULT_SELECTION_MENU_WIDTH = 250;
export const DEFAULT_SELECTION_MENU_HEIGHT = 44;
export const DEFAULT_SELECTION_MENU_GAP = 10;
export const DEFAULT_SELECTION_MENU_HORIZONTAL_INSET = 8;

export function computeSelectionMenuPlacement(input: SelectionMenuPlacementInput): SelectionMenuPlacement {
  const menuWidth = input.menuSize?.width ?? DEFAULT_SELECTION_MENU_WIDTH;
  const menuHeight = input.menuSize?.height ?? DEFAULT_SELECTION_MENU_HEIGHT;
  const gap = input.gap ?? DEFAULT_SELECTION_MENU_GAP;
  const horizontalInset = input.horizontalInset ?? DEFAULT_SELECTION_MENU_HORIZONTAL_INSET;

  const rawLeft = (input.coords.left + input.coords.right) / 2;
  const minEdge = input.shellRect.left + horizontalInset;
  const maxEdge = input.shellRect.right - horizontalInset;
  const availableWidth = maxEdge - minEdge;

  const left = availableWidth > menuWidth
    ? Math.min(maxEdge - menuWidth / 2, Math.max(minEdge + menuWidth / 2, rawLeft))
    : minEdge + availableWidth / 2;

  const topBoundary = Math.max(0, input.shellRect.top) + horizontalInset;
  const bottomBoundary = Math.min(input.viewportHeight, input.shellRect.bottom) - horizontalInset;
  const aboveTop = input.coords.top - menuHeight - gap;
  const belowTop = input.coords.bottom + gap;
  const maxTop = Math.max(topBoundary, bottomBoundary - menuHeight);
  const top = aboveTop >= topBoundary
    ? aboveTop
    : Math.min(Math.max(belowTop, topBoundary), maxTop);

  return { left, top };
}
