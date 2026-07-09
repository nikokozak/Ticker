import { EditorState, StateEffect, StateField, Transaction, type Extension, type Text } from '@codemirror/state';
import { EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { fnv1a } from '../utils/fnv1a';
import type { Span } from './ProvenanceField';

export type MarginNoteKind = 'question' | 'tension' | 'connection';
export type MarginNoteStatus = 'open' | 'dismissed' | 'promoted' | 'unanchored';

export interface MarginNote {
  noteId: string;
  streamId: string;
  anchorStart: number;
  anchorEnd: number;
  anchorHash: string;
  kind: MarginNoteKind;
  body: string;
  bodyHash: string;
  requestId?: string;
  status: MarginNoteStatus;
  createdAt: string;
}

export interface MarginCardInput {
  noteId: string;
  top: number;
  height: number;
}

export interface MarginCardLayout extends MarginCardInput {
  y: number;
}

export interface PromoteMarginNoteEdit {
  from: number;
  insert: string;
  span: Span;
}

export const setMarginNotes = StateEffect.define<MarginNote[]>();
export const updateMarginNoteStatusEffect = StateEffect.define<{ noteId: string; status: MarginNoteStatus }>();

function docLength(doc: Text | string): number {
  return typeof doc === 'string' ? doc.length : doc.length;
}

function docText(doc: Text | string, start: number, end: number): string {
  return typeof doc === 'string' ? doc.slice(start, end) : doc.sliceString(start, end);
}

function isMarginNoteKind(value: unknown): value is MarginNoteKind {
  return value === 'question' || value === 'tension' || value === 'connection';
}

function isMarginNoteStatus(value: unknown): value is MarginNoteStatus {
  return value === 'open' || value === 'dismissed' || value === 'promoted' || value === 'unanchored';
}

function integerValue(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null;
}

function readMarginNote(value: unknown): MarginNote | null {
  if (!value || typeof value !== 'object') return null;
  const candidate = value as Record<string, unknown>;
  const anchorStart = integerValue(candidate.anchorStart);
  const anchorEnd = integerValue(candidate.anchorEnd);
  if (
    typeof candidate.noteId !== 'string' ||
    typeof candidate.streamId !== 'string' ||
    anchorStart === null ||
    anchorEnd === null ||
    typeof candidate.anchorHash !== 'string' ||
    !isMarginNoteKind(candidate.kind) ||
    typeof candidate.body !== 'string' ||
    typeof candidate.bodyHash !== 'string' ||
    !isMarginNoteStatus(candidate.status) ||
    typeof candidate.createdAt !== 'string'
  ) {
    return null;
  }

  return {
    noteId: candidate.noteId,
    streamId: candidate.streamId,
    anchorStart,
    anchorEnd,
    anchorHash: candidate.anchorHash,
    kind: candidate.kind,
    body: candidate.body,
    bodyHash: candidate.bodyHash,
    requestId: typeof candidate.requestId === 'string' ? candidate.requestId : undefined,
    status: candidate.status,
    createdAt: candidate.createdAt,
  };
}

export function normalizeMarginNoteAnchors(notes: MarginNote[], doc: Text | string): MarginNote[] {
  const length = docLength(doc);
  return notes.map((note) => {
    if (note.status !== 'open') return note;
    if (note.anchorStart < 0 || note.anchorEnd <= note.anchorStart || note.anchorEnd > length) {
      return { ...note, status: 'unanchored' };
    }
    return fnv1a(docText(doc, note.anchorStart, note.anchorEnd)) === note.anchorHash
      ? note
      : { ...note, status: 'unanchored' };
  });
}

export function payloadMarginNotesForDoc(value: unknown, doc: Text | string): MarginNote[] {
  if (!Array.isArray(value)) return [];
  return normalizeMarginNoteAnchors(value.flatMap((item) => {
    const note = readMarginNote(item);
    return note ? [note] : [];
  }), doc);
}

function insertionChanges(transaction: Transaction) {
  const insertions: Array<{ from: number; length: number }> = [];
  transaction.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    if (fromA === toA && inserted.length > 0) {
      insertions.push({ from: fromA, length: inserted.length });
    }
  });
  return insertions;
}

function mapBoundaryStart(note: MarginNote, transaction: Transaction, insertions: Array<{ from: number; length: number }>): number {
  let start = transaction.changes.mapPos(note.anchorStart, -1);
  for (const insertion of insertions) {
    if (insertion.from === note.anchorStart) start += insertion.length;
  }
  return start;
}

function mapBoundaryEnd(note: MarginNote, transaction: Transaction, insertions: Array<{ from: number; length: number }>): number {
  let end = transaction.changes.mapPos(note.anchorEnd, 1);
  for (const insertion of insertions) {
    if (insertion.from === note.anchorEnd) end -= insertion.length;
  }
  return end;
}

function mapNote(note: MarginNote, transaction: Transaction, insertions: Array<{ from: number; length: number }>): MarginNote {
  if (note.status !== 'open') return note;
  return {
    ...note,
    anchorStart: mapBoundaryStart(note, transaction, insertions),
    anchorEnd: mapBoundaryEnd(note, transaction, insertions),
  };
}

export const marginNotesField: StateField<MarginNote[]> = StateField.define<MarginNote[]>({
  create: () => [],
  update(notes, transaction) {
    let next = transaction.docChanged
      ? notes.map((note) => mapNote(note, transaction, insertionChanges(transaction)))
      : notes;

    for (const effect of transaction.effects) {
      if (effect.is(setMarginNotes)) {
        next = effect.value;
      } else if (effect.is(updateMarginNoteStatusEffect)) {
        next = next.map((note) => (
          note.noteId === effect.value.noteId ? { ...note, status: effect.value.status } : note
        ));
      }
    }

    return normalizeMarginNoteAnchors(next, transaction.state.doc);
  },
});

export function currentMarginNotes(state: EditorState): MarginNote[] {
  return state.field(marginNotesField, false) ?? [];
}

export function stackMarginCards(cards: MarginCardInput[], gap = 8): MarginCardLayout[] {
  const sorted = [...cards].sort((a, b) => a.top - b.top || a.noteId.localeCompare(b.noteId));
  const result: MarginCardLayout[] = [];
  let bottom = Number.NEGATIVE_INFINITY;

  for (const card of sorted) {
    const y = Math.max(card.top, bottom + gap);
    result.push({ ...card, y });
    bottom = y + card.height;
  }

  return result;
}

export function paragraphEndForAnchor(doc: string, anchorEnd: number): number {
  const pos = Math.max(0, Math.min(anchorEnd, doc.length));
  let end = doc.indexOf('\n', pos);
  if (end < 0) return doc.length;

  while (end < doc.length) {
    const nextStart = end + 1;
    const nextEnd = doc.indexOf('\n', nextStart);
    const lineEnd = nextEnd < 0 ? doc.length : nextEnd;
    if (!doc.slice(nextStart, lineEnd).trim()) break;
    end = lineEnd;
    if (nextEnd < 0) break;
  }

  return end;
}

export function buildPromoteMarginNoteEdit(
  note: MarginNote,
  doc: string,
  options: { spanId?: string; createdAt?: number } = {}
): PromoteMarginNoteEdit | null {
  if (note.status !== 'open') return null;
  const body = note.body.trim();
  if (!body) return null;

  const from = paragraphEndForAnchor(doc, note.anchorEnd);
  const insert = `\n\n${body}`;
  const span: Span = {
    spanId: options.spanId ?? crypto.randomUUID(),
    start: from,
    end: from + insert.length,
    origin: 'ai',
    requestId: note.requestId,
    meta: { verb: 'readBack', marginNoteId: note.noteId, kind: note.kind },
    textHash: fnv1a(insert),
    createdAt: options.createdAt ?? Date.now(),
  };

  return { from, insert, span };
}

interface MarginNotesExtensionOptions {
  visible: boolean;
  onPromote: (note: MarginNote) => void;
  onDismiss: (note: MarginNote) => void;
  onUnanchor: (note: MarginNote) => void;
}

function visibleNotes(view: EditorView): MarginNote[] {
  return currentMarginNotes(view.state).filter((note) => note.status === 'open' || note.status === 'unanchored');
}

function kindClass(note: MarginNote): string {
  return `cm-margin-note--${note.kind}`;
}

function actionButton(label: string, onClick: () => void): HTMLButtonElement {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'cm-margin-note-action';
  button.textContent = label;
  button.onmousedown = (event) => event.preventDefault();
  button.onclick = onClick;
  return button;
}

function renderNoteCard(note: MarginNote, options: MarginNotesExtensionOptions): HTMLElement {
  const card = document.createElement('div');
  card.className = [
    'cm-margin-note-card',
    kindClass(note),
    note.status === 'unanchored' ? 'cm-margin-note-card--unanchored' : '',
  ].filter(Boolean).join(' ');

  const chip = document.createElement('div');
  chip.className = 'cm-margin-note-chip';
  chip.textContent = note.status === 'unanchored' ? 'passage changed' : note.kind;
  card.append(chip);

  const body = document.createElement('div');
  body.className = 'cm-margin-note-body';
  body.textContent = note.body;
  card.append(body);

  const actions = document.createElement('div');
  actions.className = 'cm-margin-note-actions';
  if (note.status === 'open') {
    actions.append(actionButton('↑ promote', () => options.onPromote(note)));
  }
  actions.append(actionButton('× dismiss', () => options.onDismiss(note)));
  card.append(actions);

  return card;
}

class MarginNotesView {
  private layer: HTMLElement;
  private popoverNoteId: string | null = null;
  private readonly resize = () => this.render(this.view);

  constructor(private readonly view: EditorView, private readonly options: MarginNotesExtensionOptions) {
    this.layer = document.createElement('div');
    this.layer.className = 'cm-margin-notes-layer';
    view.dom.append(this.layer);
    window.addEventListener('resize', this.resize);
    this.render(view);
  }

  update(update: ViewUpdate): void {
    this.reportNewUnanchors(update);
    if (
      update.docChanged ||
      update.viewportChanged ||
      update.geometryChanged ||
      currentMarginNotes(update.startState) !== currentMarginNotes(update.state)
    ) {
      this.render(update.view);
    }
  }

  destroy(): void {
    window.removeEventListener('resize', this.resize);
    this.layer.remove();
  }

  private reportNewUnanchors(update: ViewUpdate): void {
    const previous = new Map(currentMarginNotes(update.startState).map((note) => [note.noteId, note.status]));
    for (const note of currentMarginNotes(update.state)) {
      if (note.status === 'unanchored' && previous.get(note.noteId) === 'open') {
        this.options.onUnanchor(note);
      }
    }
  }

  private render(view: EditorView): void {
    this.layer.replaceChildren();
    if (!this.options.visible) return;

    const notes = visibleNotes(view);
    if (notes.length === 0) return;

    if (window.innerWidth >= 1100) {
      this.renderWide(view, notes);
    } else {
      this.renderNarrow(view, notes);
    }
  }

  private renderWide(view: EditorView, notes: MarginNote[]): void {
    const hostRect = view.dom.getBoundingClientRect();
    const contentRect = view.dom.querySelector('.cm-content')?.getBoundingClientRect() ?? hostRect;
    const left = contentRect.right - hostRect.left + 24;
    const topBase = contentRect.top - hostRect.top;
    const cards: Array<{ note: MarginNote; element: HTMLElement; top: number }> = [];

    for (const note of notes) {
      const coords = note.status === 'unanchored' ? null : view.coordsAtPos(note.anchorStart);
      if (note.status === 'open' && !coords) continue;
      const card = renderNoteCard(note, this.options);
      card.classList.add('cm-margin-note-card--wide');
      card.style.left = `${left}px`;
      card.style.width = '200px';
      card.style.top = '0px';
      this.layer.append(card);
      cards.push({
        note,
        element: card,
        top: note.status === 'unanchored' ? topBase : (coords!.top - hostRect.top),
      });
    }

    const layout = stackMarginCards(cards.map(({ note, element, top }) => ({
      noteId: note.noteId,
      top,
      height: element.offsetHeight || 88,
    })));
    const yById = new Map(layout.map((item) => [item.noteId, item.y]));
    for (const card of cards) {
      card.element.style.top = `${yById.get(card.note.noteId) ?? card.top}px`;
    }
  }

  private renderNarrow(view: EditorView, notes: MarginNote[]): void {
    const hostRect = view.dom.getBoundingClientRect();
    const contentRect = view.dom.querySelector('.cm-content')?.getBoundingClientRect() ?? hostRect;
    const dotLeft = contentRect.left - hostRect.left - 16;
    const cardLeft = Math.max(8, contentRect.left - hostRect.left);
    const topBase = contentRect.top - hostRect.top;

    for (const note of notes) {
      if (note.status === 'unanchored') {
        const card = renderNoteCard(note, this.options);
        card.classList.add('cm-margin-note-popover');
        card.style.left = `${cardLeft}px`;
        card.style.top = `${topBase}px`;
        this.layer.append(card);
        continue;
      }

      const coords = view.coordsAtPos(note.anchorStart);
      if (!coords) continue;
      const dot = document.createElement('button');
      dot.type = 'button';
      dot.className = ['cm-margin-note-dot', kindClass(note)].join(' ');
      dot.style.left = `${dotLeft}px`;
      dot.style.top = `${coords.top - hostRect.top}px`;
      dot.title = note.kind;
      dot.setAttribute('aria-label', `Open ${note.kind} margin note`);
      dot.onmousedown = (event) => event.preventDefault();
      dot.onclick = () => {
        this.popoverNoteId = this.popoverNoteId === note.noteId ? null : note.noteId;
        this.render(view);
      };
      this.layer.append(dot);

      if (this.popoverNoteId === note.noteId) {
        const card = renderNoteCard(note, this.options);
        card.classList.add('cm-margin-note-popover');
        card.style.left = `${cardLeft}px`;
        card.style.top = `${coords.bottom - hostRect.top + 8}px`;
        this.layer.append(card);
      }
    }
  }
}

export function marginNotesExtension(options: MarginNotesExtensionOptions): Extension {
  return ViewPlugin.define((view) => new MarginNotesView(view, options));
}
