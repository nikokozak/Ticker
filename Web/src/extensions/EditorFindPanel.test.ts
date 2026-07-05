import { describe, expect, it } from 'vitest';
import { deriveEditorFindCount, formatEditorFindCount } from './EditorFindPanel';

describe('editor find count formatting', () => {
  it('reports the exact selected match index', () => {
    const count = deriveEditorFindCount(
      [
        { from: 2, to: 6 },
        { from: 12, to: 16 },
        { from: 22, to: 26 },
      ],
      { from: 12, to: 16 },
      false,
    );

    expect(formatEditorFindCount(count)).toBe('2 of 3');
  });

  it('uses the next match when the editor selection is between matches', () => {
    const count = deriveEditorFindCount(
      [
        { from: 2, to: 6 },
        { from: 12, to: 16 },
      ],
      { from: 8, to: 8 },
      false,
    );

    expect(formatEditorFindCount(count)).toBe('2 of 2');
  });

  it('shows the empty state without a cap suffix', () => {
    expect(formatEditorFindCount(deriveEditorFindCount([], { from: 0, to: 0 }, true))).toBe('0 of 0');
  });

  it('marks capped totals with a plus suffix', () => {
    expect(formatEditorFindCount({ current: 4, total: 999, capped: true })).toBe('4 of 999+');
  });
});
