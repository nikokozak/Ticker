import { EditorState, StateEffect, StateField, type Extension } from '@codemirror/state';
import { Decoration, EditorView } from '@codemirror/view';

export interface AiWritingRange {
  from: number;
  to: number;
}

export const AI_HISTORY_USER_EVENT = 'input.type.ai';

export const setAiWritingRangeEffect = StateEffect.define<AiWritingRange | null>();

export const aiWritingRangeField = StateField.define<AiWritingRange | null>({
  create: () => null,
  update(range, transaction) {
    let nextRange = range;

    if (nextRange && transaction.docChanged) {
      nextRange = {
        from: transaction.changes.mapPos(nextRange.from, -1),
        to: transaction.changes.mapPos(nextRange.to, 1),
      };
    }

    for (const effect of transaction.effects) {
      if (effect.is(setAiWritingRangeEffect)) {
        nextRange = effect.value;
      }
    }

    return nextRange;
  },
  provide: (field) => EditorView.decorations.from(field, (range) => {
    if (!range || range.to <= range.from) return Decoration.none;
    return Decoration.set([
      Decoration.mark({ class: 'cm-ai-writing-range' }).range(range.from, range.to),
    ]);
  }),
});

export const aiWritingExtension: Extension = aiWritingRangeField;

export function getAiWritingRange(state: EditorState): AiWritingRange | null {
  return state.field(aiWritingRangeField, false) ?? null;
}
