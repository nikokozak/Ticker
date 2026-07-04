import { EditorSelection, EditorState, type ChangeSpec, type SelectionRange } from '@codemirror/state';

export interface InlineMarkToggle {
  changes: ChangeSpec[];
  newSelection: EditorSelection;
}

export function toggleInlineMark(
  state: EditorState,
  selection: SelectionRange,
  marker: string,
): InlineMarkToggle | null {
  if (!marker || selection.empty) return null;

  const { from, to } = selection;
  const markerLength = marker.length;
  const selectedText = state.sliceDoc(from, to);

  if (isExactlyWrapped(selectedText, marker)) {
    return {
      changes: [
        { from, to: from + markerLength },
        { from: to - markerLength, to },
      ],
      newSelection: EditorSelection.single(from, to - markerLength * 2),
    };
  }

  if (hasOutsideMarkers(state, from, to, marker)) {
    return {
      changes: [
        { from: from - markerLength, to: from },
        { from: to, to: to + markerLength },
      ],
      newSelection: EditorSelection.single(from - markerLength, to - markerLength),
    };
  }

  return {
    changes: [
      { from, insert: marker },
      { from: to, insert: marker },
    ],
    newSelection: EditorSelection.single(from + markerLength, to + markerLength),
  };
}

function isExactlyWrapped(text: string, marker: string): boolean {
  if (text.length < marker.length * 2) return false;
  if (marker === '*') {
    return countLeading(text, '*') % 2 === 1 && countTrailing(text, '*') % 2 === 1;
  }
  return text.startsWith(marker) && text.endsWith(marker);
}

function hasOutsideMarkers(state: EditorState, from: number, to: number, marker: string): boolean {
  const markerLength = marker.length;
  if (from < markerLength || to + markerLength > state.doc.length) return false;
  if (state.sliceDoc(from - markerLength, from) !== marker) return false;
  if (state.sliceDoc(to, to + markerLength) !== marker) return false;
  if (marker === '*') {
    return countRepeatedBefore(state, from, '*') % 2 === 1
      && countRepeatedAfter(state, to, '*') % 2 === 1;
  }
  return true;
}

function countLeading(text: string, char: string): number {
  let count = 0;
  while (text[count] === char) count += 1;
  return count;
}

function countTrailing(text: string, char: string): number {
  let count = 0;
  while (text[text.length - count - 1] === char) count += 1;
  return count;
}

function countRepeatedBefore(state: EditorState, position: number, char: string): number {
  let count = 0;
  while (position - count - 1 >= 0 && state.sliceDoc(position - count - 1, position - count) === char) {
    count += 1;
  }
  return count;
}

function countRepeatedAfter(state: EditorState, position: number, char: string): number {
  let count = 0;
  while (position + count < state.doc.length && state.sliceDoc(position + count, position + count + 1) === char) {
    count += 1;
  }
  return count;
}
