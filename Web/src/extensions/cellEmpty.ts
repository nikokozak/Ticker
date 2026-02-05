import { Node as ProseMirrorNode } from '@tiptap/pm/model';

/**
 * Check if a cellBlock node is semantically empty.
 *
 * A cell is empty if it contains:
 * - No text (or only whitespace)
 * - No meaningful atom/leaf nodes (images, mentions, etc.)
 * - hardBreak nodes are NOT considered meaningful content
 *
 * Used by:
 * - CellKeymap: Backspace at cell start only deletes empty cells
 * - UnifiedStreamEditor: Auto-reset AI cells when they become empty
 *
 * @param cellBlockNode - The cellBlock ProseMirror node to check
 * @returns true if the cell has no meaningful content
 */
export function isCellNodeEmpty(cellBlockNode: ProseMirrorNode): boolean {
  let hasMeaningfulContent = false;

  cellBlockNode.descendants((node) => {
    if (hasMeaningfulContent) return false;

    if (node.isText) {
      if ((node.text ?? '').trim().length > 0) {
        hasMeaningfulContent = true;
        return false;
      }
      return true;
    }

    // Atom/leaf nodes are meaningful (images, mentions, etc.), except hardBreak.
    if (node.isAtom || node.isLeaf) {
      if (node.type.name !== 'hardBreak') {
        hasMeaningfulContent = true;
        return false;
      }
    }

    return true;
  });

  return !hasMeaningfulContent;
}
