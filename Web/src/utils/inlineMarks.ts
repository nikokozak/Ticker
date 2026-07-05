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
  if (state.sliceDoc(from, to).includes('\n')) {
    return toggleMultilineInlineMark(state, from, to, marker);
  }

  return toggleSingleLineInlineMark(state, from, to, marker);
}

function toggleSingleLineInlineMark(
  state: EditorState,
  from: number,
  to: number,
  marker: string,
): InlineMarkToggle | null {
  const core = trimmedRange(state, from, to);
  if (!core) return null;

  const markerLength = marker.length;
  const selectedText = state.sliceDoc(core.from, core.to);

  if (isExactlyWrapped(selectedText, marker)) {
    return {
      changes: [
        { from: core.from, to: core.from + markerLength },
        { from: core.to - markerLength, to: core.to },
      ],
      newSelection: EditorSelection.single(core.from, core.to - markerLength * 2),
    };
  }

  if (hasOutsideMarkers(state, core.from, core.to, marker)) {
    return {
      changes: [
        { from: core.from - markerLength, to: core.from },
        { from: core.to, to: core.to + markerLength },
      ],
      newSelection: EditorSelection.single(core.from - markerLength, core.to - markerLength),
    };
  }

  return {
    changes: [
      { from: core.from, insert: marker },
      { from: core.to, insert: marker },
    ],
    newSelection: EditorSelection.single(core.from + markerLength, core.to + markerLength),
  };
}

interface TextRange {
  from: number;
  to: number;
}

interface UnwrapAction {
  range: TextRange;
  contentFrom: number;
  contentTo: number;
}

function toggleMultilineInlineMark(
  state: EditorState,
  from: number,
  to: number,
  marker: string,
): InlineMarkToggle | null {
  const cores = trimmedLineRanges(state, from, to);
  if (cores.length === 0) return null;

  const unwrapActions = cores.map((core) => unwrapActionForRange(state, core, marker));
  if (unwrapActions.every((action): action is UnwrapAction => action !== null)) {
    return unwrapLineRanges(unwrapActions, marker);
  }

  const rangesToWrap = cores.filter((_core, index) => unwrapActions[index] === null);
  if (rangesToWrap.length === 0) return null;
  return wrapLineRanges(rangesToWrap, marker);
}

function wrapLineRanges(ranges: TextRange[], marker: string): InlineMarkToggle {
  const changes: ChangeSpec[] = [];
  for (const range of ranges) {
    changes.push({ from: range.from, insert: marker });
    changes.push({ from: range.to, insert: marker });
  }

  const firstRange = ranges[0];
  const lastRange = ranges[ranges.length - 1];
  return {
    changes,
    newSelection: EditorSelection.single(
      firstRange.from,
      mapPositionAcrossInsertions(lastRange.to, changes),
    ),
  };
}

function unwrapLineRanges(actions: UnwrapAction[], marker: string): InlineMarkToggle {
  const markerLength = marker.length;
  const changes: ChangeSpec[] = [];

  for (const action of actions) {
    changes.push({ from: action.range.from, to: action.range.from + markerLength });
    changes.push({ from: action.range.to - markerLength, to: action.range.to });
  }

  const firstAction = actions[0];
  const lastAction = actions[actions.length - 1];
  return {
    changes,
    newSelection: EditorSelection.single(
      mapPositionAcrossDeletions(firstAction.contentFrom, changes),
      mapPositionAcrossDeletions(lastAction.contentTo, changes),
    ),
  };
}

function unwrapActionForRange(state: EditorState, range: TextRange, marker: string): UnwrapAction | null {
  const markerLength = marker.length;
  const selectedText = state.sliceDoc(range.from, range.to);

  if (isExactlyWrapped(selectedText, marker)) {
    return {
      range,
      contentFrom: range.from + markerLength,
      contentTo: range.to - markerLength,
    };
  }

  if (hasOutsideMarkers(state, range.from, range.to, marker)) {
    return {
      range: {
        from: range.from - markerLength,
        to: range.to + markerLength,
      },
      contentFrom: range.from,
      contentTo: range.to,
    };
  }

  return null;
}

function trimmedRange(state: EditorState, from: number, to: number): TextRange | null {
  const text = state.sliceDoc(from, to);
  const leading = text.search(/\S/);
  if (leading === -1) return null;

  let trailing = text.length;
  while (trailing > leading && /\s/.test(text[trailing - 1])) {
    trailing -= 1;
  }

  return {
    from: from + leading,
    to: from + trailing,
  };
}

function trimmedLineRanges(state: EditorState, from: number, to: number): TextRange[] {
  const ranges: TextRange[] = [];
  let position = from;

  while (position < to) {
    const line = state.doc.lineAt(position);
    const lineRange = trimmedRange(state, position, Math.min(line.to, to));
    if (lineRange) ranges.push(lineRange);

    if (line.to >= to) break;
    position = line.to + 1;
  }

  return ranges;
}

function mapPositionAcrossInsertions(position: number, changes: ChangeSpec[]): number {
  let mapped = position;
  for (const change of changes) {
    if ('insert' in change && typeof change.from === 'number' && change.from <= position) {
      mapped += String(change.insert).length;
    }
  }
  return mapped;
}

function mapPositionAcrossDeletions(position: number, changes: ChangeSpec[]): number {
  let mapped = position;
  for (const change of changes) {
    if ('to' in change && typeof change.from === 'number' && typeof change.to === 'number' && change.to <= position) {
      mapped -= change.to - change.from;
    }
  }
  return mapped;
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
