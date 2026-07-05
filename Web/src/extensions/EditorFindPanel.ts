import { EditorSelection } from '@codemirror/state';
import {
  EditorView,
  runScopeHandlers,
  type Panel,
  type ViewUpdate,
} from '@codemirror/view';
import {
  findNext,
  findPrevious,
  getSearchQuery,
  SearchQuery,
  search,
  setSearchQuery,
} from '@codemirror/search';

const MAX_DISPLAYED_MATCHES = 999;

export interface EditorFindMatch {
  from: number;
  to: number;
}

export interface EditorFindCount {
  current: number;
  total: number;
  capped: boolean;
}

export function deriveEditorFindCount(
  matches: readonly EditorFindMatch[],
  selection: EditorFindMatch,
  capped: boolean,
): EditorFindCount {
  if (matches.length === 0) {
    return { current: 0, total: 0, capped: false };
  }

  let currentIndex = matches.findIndex((match) => match.from === selection.from && match.to === selection.to);
  if (currentIndex === -1) {
    currentIndex = matches.findIndex((match) => match.from >= selection.from);
  }
  if (currentIndex === -1) {
    currentIndex = 0;
  }

  return {
    current: currentIndex + 1,
    total: matches.length,
    capped,
  };
}

export function formatEditorFindCount(count: EditorFindCount): string {
  if (count.total === 0) {
    return '0 of 0';
  }

  return `${count.current} of ${count.total}${count.capped ? '+' : ''}`;
}

function collectMatches(view: EditorView, query: SearchQuery): { matches: EditorFindMatch[]; capped: boolean } {
  if (!query.valid) {
    return { matches: [], capped: false };
  }

  const cursor = query.getCursor(view.state);
  const matches: EditorFindMatch[] = [];

  while (matches.length < MAX_DISPLAYED_MATCHES) {
    const result = cursor.next();
    if (result.done) {
      return { matches, capped: false };
    }
    matches.push({ from: result.value.from, to: result.value.to });
  }

  return { matches, capped: !cursor.next().done };
}

function findMatchFrom(view: EditorView, query: SearchQuery, anchor: number): EditorFindMatch | null {
  if (!query.valid) {
    return null;
  }

  const clampedAnchor = Math.max(0, Math.min(anchor, view.state.doc.length));
  let cursor = query.getCursor(view.state, clampedAnchor);
  let result = cursor.next();
  if (!result.done) {
    return { from: result.value.from, to: result.value.to };
  }

  if (clampedAnchor === 0) {
    return null;
  }

  cursor = query.getCursor(view.state, 0, clampedAnchor);
  result = cursor.next();
  return result.done ? null : { from: result.value.from, to: result.value.to };
}

function selectNearestMatch(view: EditorView, query: SearchQuery, anchor: number): void {
  const match = findMatchFrom(view, query, anchor);
  if (!match) {
    return;
  }

  const selection = EditorSelection.single(match.from, match.to);
  view.dispatch({
    selection,
    effects: EditorView.scrollIntoView(selection.main),
    userEvent: 'select.search',
  });
}

function createLiteralQuery(searchText: string): SearchQuery {
  return new SearchQuery({
    search: searchText,
    caseSensitive: false,
    literal: true,
  });
}

class EditorFindPanel implements Panel {
  readonly dom: HTMLElement;
  readonly top = true;

  private query: SearchQuery;
  private readonly input: HTMLInputElement;
  private readonly count: HTMLSpanElement;

  constructor(private readonly view: EditorView) {
    this.query = getSearchQuery(view.state);
    this.input = document.createElement('input');
    this.input.type = 'text';
    this.input.placeholder = 'Find';
    this.input.value = this.query.search;
    this.input.spellcheck = false;
    this.input.autocomplete = 'off';
    this.input.setAttribute('aria-label', 'Find');
    this.input.setAttribute('main-field', 'true');
    this.input.className = 'editor-find-input';

    this.count = document.createElement('span');
    this.count.className = 'editor-find-count';
    this.count.setAttribute('aria-live', 'polite');

    const previousButton = this.createButton('Previous match', '\u2039', () => findPrevious(this.view));
    const nextButton = this.createButton('Next match', '\u203a', () => findNext(this.view));

    this.dom = document.createElement('div');
    this.dom.className = 'editor-find-panel';
    this.dom.append(this.input, this.count, previousButton, nextButton);

    this.input.addEventListener('input', this.handleInput);
    this.dom.addEventListener('keydown', this.handleKeyDown);
    this.refreshCount();
  }

  mount(): void {
    this.input.focus();
    this.input.select();
  }

  update(update: ViewUpdate): void {
    const query = getSearchQuery(update.state);
    const queryChanged = !query.eq(this.query);

    if (queryChanged) {
      this.query = query;
      if (this.input.value !== query.search) {
        this.input.value = query.search;
      }
    }

    if (queryChanged || update.docChanged || update.selectionSet) {
      this.refreshCount();
    }
  }

  destroy(): void {
    this.input.removeEventListener('input', this.handleInput);
    this.dom.removeEventListener('keydown', this.handleKeyDown);
  }

  private createButton(label: string, text: string, action: () => boolean): HTMLButtonElement {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'editor-find-button';
    button.textContent = text;
    button.setAttribute('aria-label', label);
    button.title = label;
    button.addEventListener('mousedown', (event) => {
      event.preventDefault();
    });
    button.addEventListener('click', () => {
      action();
    });
    return button;
  }

  private handleInput = (): void => {
    const anchor = this.view.state.selection.main.from;
    const query = createLiteralQuery(this.input.value);
    this.query = query;
    this.view.dispatch({ effects: setSearchQuery.of(query) });
    selectNearestMatch(this.view, query, anchor);
    this.refreshCount();
  };

  private handleKeyDown = (event: KeyboardEvent): void => {
    if (runScopeHandlers(this.view, event, 'search-panel')) {
      event.preventDefault();
      return;
    }

    if (event.key === 'Enter') {
      event.preventDefault();
      (event.shiftKey ? findPrevious : findNext)(this.view);
    }
  };

  private refreshCount(): void {
    const query = getSearchQuery(this.view.state);
    const { matches, capped } = collectMatches(this.view, query);
    const selection = this.view.state.selection.main;
    this.count.textContent = formatEditorFindCount(
      deriveEditorFindCount(matches, { from: selection.from, to: selection.to }, capped),
    );
  }
}

export const editorFindExtension = search({
  top: true,
  literal: true,
  caseSensitive: false,
  createPanel: (view) => new EditorFindPanel(view),
});
