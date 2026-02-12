import { Extension } from '@tiptap/core';
import { Plugin, PluginKey, Selection } from '@tiptap/pm/state';
import { Node as ProseMirrorNode } from '@tiptap/pm/model';
import { isCellNodeEmpty } from './cellEmpty';
import { IS_DEV, debugLog, debugWarn } from '../utils/debug';

/**
 * Callbacks for cell lifecycle events.
 * StreamEditor provides these to sync store + persistence.
 */
export interface CellKeymapCallbacks {
  /** Called when Enter creates a new cell. Returns the new cell's UUID. */
  onCreateCell: (afterCellId: string) => string;
  /** Called when Backspace deletes an empty cell. */
  onDeleteCell: (cellId: string) => void;
  /** Called when Cmd+Enter triggers AI thinking. */
  onThink?: (cellId: string) => void;
}

/**
 * CellKeymap extension - handles Enter, Backspace, and Arrow keys at cell boundaries.
 *
 * Slice 04: Restores "cell-based" feel while allowing rich formatting inside cells.
 *
 * Rules:
 * - Enter at end of last block in cell → create new cellBlock after it
 * - Backspace at start of first block in empty cell → delete cell, move to previous
 * - ArrowUp at start of cell → move to end of previous cell
 * - ArrowDown at end of cell → move to start of next cell
 */
export const CellKeymap = Extension.create<{ callbacks: CellKeymapCallbacks | null }>({
  name: 'cellKeymap',

  addOptions() {
    return {
      callbacks: null,
    };
  },

  addProseMirrorPlugins() {
    const { callbacks } = this.options;

    return [
      new Plugin({
        key: new PluginKey('cellKeymap'),

        props: {
          handleKeyDown: (view, event) => {
            const { state, dispatch } = view;
            const { selection, doc, schema } = state;
            const { $from, empty } = selection;

            // Only handle when selection is collapsed (cursor, not range)
            if (!empty) return false;

            // Find the cellBlock containing the cursor
            let cellBlockPos: number | null = null;
            let cellBlockNode: ProseMirrorNode | null = null;

            for (let depth = $from.depth; depth >= 0; depth--) {
              const node = $from.node(depth);
              if (node.type.name === 'cellBlock') {
                cellBlockPos = $from.before(depth);
                cellBlockNode = node;
                break;
              }
            }

            if (cellBlockPos === null || !cellBlockNode) return false;

            const cellId: string | null = cellBlockNode.attrs.id ?? null;
            if (!cellId) {
              if (IS_DEV) {
                debugWarn('[CellKeymap] cellBlock missing attrs.id; refusing to do boundary ops');
              }
              return false;
            }

            const cellContentStart = cellBlockPos + 1;
            const cellContentEnd = cellBlockPos + cellBlockNode.nodeSize - 1;

            // Compute the *first* and *last* valid cursor positions inside this cell.
            // This avoids brittle “-2/-3” heuristics and works with nested structures (lists, blockquotes, etc).
            const startSelection = Selection.findFrom(doc.resolve(cellContentStart), 1, true);
            const endSelection = Selection.findFrom(doc.resolve(cellContentEnd), -1, true);
            if (!startSelection || !endSelection) return false;

            const isAtCellStart = startSelection.from === selection.from;
            const isAtCellEnd = endSelection.from === selection.from;

            // === CMD+ENTER - AI Think ===
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !event.shiftKey) {
              if (callbacks?.onThink) {
                if (IS_DEV) {
                  debugLog('[CellKeymap] Cmd+Enter - triggering AI think for cell', { cellId });
                }
                callbacks.onThink(cellId);
                return true;
              }
              return false;
            }

            // === ENTER KEY ===
            if (event.key === 'Enter' && !event.shiftKey && !event.metaKey && !event.ctrlKey) {
              // If we're inside a list item, never create a new cell on Enter.
              // Let ProseMirror handle list continuation / exiting the list.
              // Users can press Enter again after exiting the list to create a new cell.
              for (let depth = $from.depth; depth >= 0; depth--) {
                if ($from.node(depth).type.name === 'listItem') {
                  return false;
                }
              }

              if (IS_DEV) {
                debugLog('[CellKeymap] Enter check', {
                  cellId,
                  isAtCellEnd,
                });
              }

              if (!isAtCellEnd) return false;

              // Create new cell after current one
              if (!callbacks?.onCreateCell) return false;

              const newCellId = callbacks.onCreateCell(cellId);
              if (IS_DEV) {
                debugLog('[CellKeymap] Creating new cell after', { cellId, newCellId });
              }

              // Insert new cellBlock after current one
              const cellBlockType = schema.nodes.cellBlock;
              const paragraphType = schema.nodes.paragraph;
              if (!cellBlockType || !paragraphType) return false;

              const newCell = cellBlockType.create(
                { id: newCellId, type: 'text' },
                paragraphType.create()
              );

              const insertPos = cellBlockPos + cellBlockNode.nodeSize;
              const tr = state.tr.insert(insertPos, newCell);

              // Move cursor to the first valid cursor position inside the new cell.
              const newCellContentStart = insertPos + 1;
              const newSel = Selection.findFrom(tr.doc.resolve(newCellContentStart), 1, true);
              if (newSel) {
                tr.setSelection(newSel);
              }

              dispatch(tr);
              return true;

              // Default: let ProseMirror handle (new paragraph, list continuation, etc.)
              // (unreachable)
            }

            // === BACKSPACE KEY ===
            if (event.key === 'Backspace') {
              if (IS_DEV) {
                debugLog('[CellKeymap] Backspace check', {
                  cellId,
                  isAtCellStart,
                });
              }

              if (!isAtCellStart) return false;

              // Only delete if cell is truly empty (no text and no atom/leaf content like images/mentions).
              if (!isCellNodeEmpty(cellBlockNode)) return false;

              const cellIndex = findCellIndex(doc, cellBlockPos);
              if (cellIndex <= 0) return false;

              const prevCellInfo = getCellAtIndex(doc, cellIndex - 1);
              if (!prevCellInfo) return false;

              callbacks?.onDeleteCell?.(cellId);

              if (IS_DEV) {
                debugLog('[CellKeymap] Deleting empty cell', { cellId });
              }

              const tr = state.tr.delete(cellBlockPos, cellBlockPos + cellBlockNode.nodeSize);

              // Move cursor to end of previous cell (closest valid position).
              const prevEnd = prevCellInfo.pos + prevCellInfo.node.nodeSize - 1;
              const prevEndSel = Selection.findFrom(tr.doc.resolve(prevEnd), -1, true);
              if (prevEndSel) {
                tr.setSelection(prevEndSel);
              }

              dispatch(tr);
              return true;
            }

            // === ARROW UP ===
            if (event.key === 'ArrowUp') {
              if (!isAtCellStart) return false;

              const cellIndex = findCellIndex(doc, cellBlockPos);
              if (cellIndex <= 0) return false;

              const prevCellInfo = getCellAtIndex(doc, cellIndex - 1);
              if (!prevCellInfo) return false;

              const prevEnd = prevCellInfo.pos + prevCellInfo.node.nodeSize - 1;
              const prevEndSel = Selection.findFrom(state.doc.resolve(prevEnd), -1, true);
              if (!prevEndSel) return false;

              dispatch(state.tr.setSelection(prevEndSel));
              return true;
            }

            // === ARROW DOWN ===
            if (event.key === 'ArrowDown') {
              if (!isAtCellEnd) return false;

              const cellIndex = findCellIndex(doc, cellBlockPos);
              const totalCells = countCells(doc);
              if (cellIndex < 0 || cellIndex >= totalCells - 1) return false;

              const nextCellInfo = getCellAtIndex(doc, cellIndex + 1);
              if (!nextCellInfo) return false;

              const nextStart = nextCellInfo.pos + 1;
              const nextStartSel = Selection.findFrom(state.doc.resolve(nextStart), 1, true);
              if (!nextStartSel) return false;

              dispatch(state.tr.setSelection(nextStartSel));
              return true;
            }

            return false;
          },
        },
      }),
    ];
  },
});

// NOTE: isCellNodeEmpty is imported from ./cellEmpty.ts so empty-cell behavior stays consistent.

/**
 * Find the index of a cellBlock in the document by its position.
 */
function findCellIndex(doc: ProseMirrorNode, cellPos: number): number {
  let index = 0;
  let found = -1;
  doc.forEach((node, offset) => {
    if (node.type.name === 'cellBlock') {
      if (offset === cellPos) {
        found = index;
      }
      index++;
    }
  });
  return found;
}

/**
 * Get cell info at a specific index.
 */
function getCellAtIndex(doc: ProseMirrorNode, targetIndex: number): { pos: number; node: ProseMirrorNode } | null {
  let index = 0;
  let result: { pos: number; node: ProseMirrorNode } | null = null;
  doc.forEach((node, offset) => {
    if (node.type.name === 'cellBlock') {
      if (index === targetIndex) {
        result = { pos: offset, node };
      }
      index++;
    }
  });
  return result;
}

/**
 * Count total cellBlocks in document.
 */
function countCells(doc: ProseMirrorNode): number {
  let count = 0;
  doc.forEach((node) => {
    if (node.type.name === 'cellBlock') {
      count++;
    }
  });
  return count;
}
