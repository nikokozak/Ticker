import { EditorSelection, type ChangeSpec, type EditorState, type SelectionRange, type StateCommand } from '@codemirror/state';

export type LineFormat = 'h1' | 'h2' | 'h3' | 'quote' | 'bullet';

const MARKER_TEXT: Record<LineFormat, string> = {
  h1: '# ',
  h2: '## ',
  h3: '### ',
  quote: '> ',
  bullet: '- ',
};

// Leading indent, then any existing line-format marker (heading, quote, or
// list bullet) with its trailing spaces.
const LINE_MARKER = /^(\s*)((?:#{1,6}|>|[-*+])\s+)?/;

function formatOfMarker(marker: string): LineFormat | null {
  const bare = marker.trimEnd();
  if (bare === '#') return 'h1';
  if (bare === '##') return 'h2';
  if (bare === '###') return 'h3';
  if (bare === '>') return 'quote';
  if (bare === '-' || bare === '*' || bare === '+') return 'bullet';
  return null;
}

const BULLET_LINE = /^(\s*)([-*+])(\s+)/;

/**
 * Enter on a bullet line: always-tight continuation — the next bullet goes on
 * the immediately following line, regardless of the underlying markdown
 * list's loose/tight spacing (the stock markdown command inserts a blank line
 * for loose lists). Enter on an empty item removes the marker and exits.
 * Falls through (false) on non-bullet lines.
 */
export const continueBulletListOnEnter: StateCommand = ({ state, dispatch }) => {
  const range = state.selection.main;
  if (!range.empty) return false;
  const line = state.doc.lineAt(range.head);
  const match = BULLET_LINE.exec(line.text);
  if (!match) return false;
  const markerEnd = line.from + match[0].length;
  if (range.head < markerEnd) return false;

  if (markerEnd === line.to) {
    // Empty item: drop the marker and exit the list.
    dispatch(state.update({
      changes: { from: line.from, to: line.to },
      selection: EditorSelection.cursor(line.from),
      userEvent: 'delete',
    }));
    return true;
  }

  const insert = `\n${match[1]}${match[2]}${match[3]}`;
  dispatch(state.update({
    changes: { from: range.head, insert },
    selection: EditorSelection.cursor(range.head + insert.length),
    userEvent: 'input',
  }));
  return true;
};

/**
 * Toggle a line-level markdown format on every line the selection touches.
 * All lines already in the target format → strip it; otherwise the target
 * marker replaces whatever marker each line has (switching h1 → quote etc.).
 * Blank lines are skipped. Selection maps through the changes automatically.
 */
export function toggleLineFormat(
  state: EditorState,
  selection: SelectionRange,
  format: LineFormat,
): ChangeSpec[] | null {
  const lines: Array<{ from: number; indent: string; marker: string }> = [];
  const firstLine = state.doc.lineAt(Math.min(selection.from, selection.to)).number;
  const lastLine = state.doc.lineAt(Math.max(selection.from, selection.to)).number;

  for (let lineNumber = firstLine; lineNumber <= lastLine; lineNumber += 1) {
    const line = state.doc.line(lineNumber);
    if (!line.text.trim()) continue;
    const match = LINE_MARKER.exec(line.text);
    lines.push({ from: line.from, indent: match?.[1] ?? '', marker: match?.[2] ?? '' });
  }
  if (lines.length === 0) return null;

  const allTarget = lines.every((line) => formatOfMarker(line.marker) === format);

  return lines.map((line) => {
    const markerFrom = line.from + line.indent.length;
    const markerTo = markerFrom + line.marker.length;
    return allTarget
      ? { from: markerFrom, to: markerTo }
      : { from: markerFrom, to: markerTo, insert: MARKER_TEXT[format] };
  });
}
