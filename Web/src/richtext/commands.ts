import { lift, setBlockType, toggleMark, wrapIn } from 'prosemirror-commands';
import { liftListItem, sinkListItem, splitListItem, wrapInList } from 'prosemirror-schema-list';
import type { Command, EditorState } from 'prosemirror-state';
import type { MarkType, NodeType } from 'prosemirror-model';
import { tickerSchema } from './schema';

/**
 * Formatting commands. These are what the selection menu and the keymap both call,
 * so "make this bold" has exactly one implementation.
 *
 * The point of the rewrite is visible here: every command is a structural
 * operation on nodes and marks. There is no string manipulation, no marker
 * counting, no way to select half a delimiter, and no way to end up with `****`.
 * The whole class of bug that made the markdown-as-model editor unusable is not
 * expressible in this layer.
 */

const { marks, nodes } = tickerSchema;

export const toggleBold: Command = toggleMark(marks.strong as MarkType);
export const toggleItalic: Command = toggleMark(marks.em as MarkType);
export const toggleUnderline: Command = toggleMark(marks.underline as MarkType);
export const toggleCode: Command = toggleMark(marks.code as MarkType);

/** Heading level 1-6, or 0 to return the block to a paragraph. */
export function setHeading(level: number): Command {
  if (level === 0) return setBlockType(nodes.paragraph as NodeType);
  return setBlockType(nodes.heading as NodeType, { level });
}

/** Heading of this level -> paragraph; anything else -> heading. */
export function toggleHeading(level: number): Command {
  return (state, dispatch, view) => {
    const { $from } = state.selection;
    const isAlready = $from.parent.type === nodes.heading && $from.parent.attrs.level === level;
    return setHeading(isAlready ? 0 : level)(state, dispatch, view);
  };
}

export const toggleBulletList: Command = (state, dispatch, view) => (
  isInsideList(state, 'bullet_list')
    ? liftListItem(nodes.list_item as NodeType)(state, dispatch, view)
    : wrapInList(nodes.bullet_list as NodeType)(state, dispatch, view)
);

export const toggleOrderedList: Command = (state, dispatch, view) => (
  isInsideList(state, 'ordered_list')
    ? liftListItem(nodes.list_item as NodeType)(state, dispatch, view)
    : wrapInList(nodes.ordered_list as NodeType)(state, dispatch, view)
);

export const toggleBlockquote: Command = (state, dispatch, view) => (
  isInside(state, 'blockquote')
    // ProseMirror's own lift, not a hand-rolled replace of the whole quote: a
    // replacement step maps every position inside to its boundary, so unquoting a
    // paragraph dissolved the provenance on text that had not changed at all.
    ? lift(state, dispatch)
    : wrapIn(nodes.blockquote as NodeType)(state, dispatch, view)
);

/** Shift+Enter: a line break inside the paragraph, not a new paragraph. */
export const insertSoftBreak: Command = (state, dispatch) => {
  if (dispatch) {
    dispatch(state.tr.replaceSelectionWith((nodes.soft_break as NodeType).create()).scrollIntoView());
  }
  return true;
};

export const splitListItemCommand: Command = splitListItem(nodes.list_item as NodeType);
export const indentListItem: Command = sinkListItem(nodes.list_item as NodeType);
export const outdentListItem: Command = liftListItem(nodes.list_item as NodeType);

/** True when the cursor sits inside a node of this type. */
function isInside(state: EditorState, typeName: string): boolean {
  const { $from } = state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).type.name === typeName) return true;
  }
  return false;
}

function isInsideList(state: EditorState, listType: string): boolean {
  return isInside(state, listType);
}

/** Which formatting is active, for rendering the selection menu's pressed states. */
export function activeFormats(state: EditorState): {
  bold: boolean;
  italic: boolean;
  underline: boolean;
  code: boolean;
  heading: number;
  bulletList: boolean;
  orderedList: boolean;
  blockquote: boolean;
} {
  const { from, $from, to, empty } = state.selection;
  const has = (mark: MarkType) => (empty
    ? Boolean(mark.isInSet(state.storedMarks || $from.marks()))
    : state.doc.rangeHasMark(from, to, mark));

  return {
    bold: has(marks.strong as MarkType),
    italic: has(marks.em as MarkType),
    underline: has(marks.underline as MarkType),
    code: has(marks.code as MarkType),
    heading: $from.parent.type === nodes.heading ? Number($from.parent.attrs.level) : 0,
    bulletList: isInside(state, 'bullet_list'),
    orderedList: isInside(state, 'ordered_list'),
    blockquote: isInside(state, 'blockquote'),
  };
}
