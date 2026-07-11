import { EditorSelection, EditorState, type ChangeSpec, type SelectionRange } from '@codemirror/state';

export interface InlineMarkToggle {
  changes: ChangeSpec[];
  newSelection: EditorSelection;
}

/** Symmetric markers ('**', '*', '`') pass a string; asymmetric pairs
 * (underline's '<u>'/'</u>') pass open/close explicitly. */
export interface InlineMarkPair {
  open: string;
  close: string;
}

export type InlineMarker = string | InlineMarkPair;

function normalizeMarker(marker: InlineMarker): InlineMarkPair {
  return typeof marker === 'string' ? { open: marker, close: marker } : marker;
}

export function toggleInlineMark(
  state: EditorState,
  selection: SelectionRange,
  marker: InlineMarker,
): InlineMarkToggle | null {
  const mark = normalizeMarker(marker);
  if (!mark.open || !mark.close || selection.empty) return null;

  const { from, to } = selection;
  if (state.sliceDoc(from, to).includes('\n')) {
    return toggleMultilineInlineMark(state, from, to, mark);
  }

  return toggleSingleLineInlineMark(state, from, to, mark);
}

function toggleSingleLineInlineMark(
  state: EditorState,
  from: number,
  to: number,
  mark: InlineMarkPair,
): InlineMarkToggle | null {
  const core = trimmedRange(state, from, to);
  if (!core) return null;

  const selectedText = state.sliceDoc(core.from, core.to);

  if (isExactlyWrapped(selectedText, mark)) {
    return {
      changes: [
        { from: core.from, to: core.from + mark.open.length },
        { from: core.to - mark.close.length, to: core.to },
      ],
      newSelection: EditorSelection.single(core.from, core.to - mark.open.length - mark.close.length),
    };
  }

  if (hasOutsideMarkers(state, core.from, core.to, mark)) {
    return {
      changes: [
        { from: core.from - mark.open.length, to: core.from },
        { from: core.to, to: core.to + mark.close.length },
      ],
      newSelection: EditorSelection.single(core.from - mark.open.length, core.to - mark.open.length),
    };
  }

  return {
    changes: [
      { from: core.from, insert: mark.open },
      { from: core.to, insert: mark.close },
    ],
    newSelection: EditorSelection.single(core.from + mark.open.length, core.to + mark.open.length),
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
  mark: InlineMarkPair,
): InlineMarkToggle | null {
  const cores = trimmedLineRanges(state, from, to);
  if (cores.length === 0) return null;

  const unwrapActions = cores.map((core) => unwrapActionForRange(state, core, mark));
  if (unwrapActions.every((action): action is UnwrapAction => action !== null)) {
    return unwrapLineRanges(unwrapActions, mark);
  }

  const rangesToWrap = cores.filter((_core, index) => unwrapActions[index] === null);
  if (rangesToWrap.length === 0) return null;
  return wrapLineRanges(rangesToWrap, mark);
}

function wrapLineRanges(ranges: TextRange[], mark: InlineMarkPair): InlineMarkToggle {
  const changes: ChangeSpec[] = [];
  for (const range of ranges) {
    changes.push({ from: range.from, insert: mark.open });
    changes.push({ from: range.to, insert: mark.close });
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

function unwrapLineRanges(actions: UnwrapAction[], mark: InlineMarkPair): InlineMarkToggle {
  const changes: ChangeSpec[] = [];

  for (const action of actions) {
    changes.push({ from: action.range.from, to: action.range.from + mark.open.length });
    changes.push({ from: action.range.to - mark.close.length, to: action.range.to });
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

function unwrapActionForRange(state: EditorState, range: TextRange, mark: InlineMarkPair): UnwrapAction | null {
  const selectedText = state.sliceDoc(range.from, range.to);

  if (isExactlyWrapped(selectedText, mark)) {
    return {
      range,
      contentFrom: range.from + mark.open.length,
      contentTo: range.to - mark.close.length,
    };
  }

  if (hasOutsideMarkers(state, range.from, range.to, mark)) {
    return {
      range: {
        from: range.from - mark.open.length,
        to: range.to + mark.close.length,
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

function isExactlyWrapped(text: string, mark: InlineMarkPair): boolean {
  if (text.length < mark.open.length + mark.close.length) return false;
  if (mark.open === '*' && mark.close === '*') {
    return countLeading(text, '*') % 2 === 1 && countTrailing(text, '*') % 2 === 1;
  }
  return text.startsWith(mark.open) && text.endsWith(mark.close);
}

function hasOutsideMarkers(state: EditorState, from: number, to: number, mark: InlineMarkPair): boolean {
  if (from < mark.open.length || to + mark.close.length > state.doc.length) return false;
  if (state.sliceDoc(from - mark.open.length, from) !== mark.open) return false;
  if (state.sliceDoc(to, to + mark.close.length) !== mark.close) return false;
  if (mark.open === '*' && mark.close === '*') {
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
