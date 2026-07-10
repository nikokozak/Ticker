import { EditorState, StateEffect, StateField, type Extension } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';

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
  provide: (field) => EditorView.decorations.compute([field], (state) => {
    const range = state.field(field);
    if (!range) return Decoration.none;
    // Waiting for the first chunk: the range is empty or holds only the
    // insertion prefix (newlines in 'after' mode) — pulsing dots at the
    // insertion point instead of an invisible whitespace highlight.
    if (state.doc.sliceString(range.from, range.to).trim().length === 0) {
      return Decoration.set([
        Decoration.widget({ widget: new AiPendingWidget(), side: 1 }).range(range.to),
      ]);
    }
    return Decoration.set([
      Decoration.mark({ class: 'cm-ai-writing-range' }).range(range.from, range.to),
    ]);
  }),
});

/** Inline three-dot typing indicator shown before the first streamed chunk lands. */
class AiPendingWidget extends WidgetType {
  toDOM(): HTMLElement {
    const wrap = document.createElement('span');
    wrap.className = 'cm-ai-pending';
    wrap.setAttribute('aria-label', 'AI is writing');
    for (let i = 0; i < 3; i += 1) {
      const dot = document.createElement('span');
      dot.className = 'cm-pending-append-dot';
      wrap.appendChild(dot);
    }
    return wrap;
  }

  override eq(): boolean {
    return true;
  }
}

export const aiWritingExtension: Extension = aiWritingRangeField;

export function getAiWritingRange(state: EditorState): AiWritingRange | null {
  return state.field(aiWritingRangeField, false) ?? null;
}
