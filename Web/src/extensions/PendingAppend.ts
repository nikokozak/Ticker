import { StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';

/**
 * Typing-indicator ghost line at the end of the document: shown while a
 * quick-panel AI answer is in flight, at the exact spot where it will land.
 * Communicates *where* text will arrive, not just that the app is busy.
 */
export const setPendingAppend = StateEffect.define<boolean>();

class TypingIndicatorWidget extends WidgetType {
  toDOM(): HTMLElement {
    const line = document.createElement('div');
    line.className = 'cm-pending-append';
    line.setAttribute('aria-label', 'AI is writing');
    for (let i = 0; i < 3; i += 1) {
      const dot = document.createElement('span');
      dot.className = 'cm-pending-append-dot';
      line.appendChild(dot);
    }
    return line;
  }

  override eq(): boolean {
    return true;
  }
}

function indicatorAt(pos: number): DecorationSet {
  return Decoration.set([
    Decoration.widget({ widget: new TypingIndicatorWidget(), side: 1, block: true }).range(pos),
  ]);
}

export const pendingAppendField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(decorations, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setPendingAppend)) {
        return effect.value ? indicatorAt(tr.newDoc.length) : Decoration.none;
      }
    }
    // The indicator marks the append point; keep it pinned to the doc end.
    if (tr.docChanged && decorations.size > 0) {
      return indicatorAt(tr.newDoc.length);
    }
    return decorations;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export function pendingAppendIsShown(state: { field(f: typeof pendingAppendField): DecorationSet }): boolean {
  return state.field(pendingAppendField).size > 0;
}
