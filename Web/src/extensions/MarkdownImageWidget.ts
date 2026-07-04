import { RangeSetBuilder, type Range } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from '@codemirror/view';

const MARKDOWN_IMAGE_TOKEN_REGEX = /!\[([^\]]*)\]\((ticker-asset:\/\/[^)]+)\)(?:\{width=(\d{2,4})\})?/g;
const MIN_IMAGE_WIDTH = 120;
const DEFAULT_MAX_IMAGE_WIDTH = 920;

export interface MarkdownImageToken {
  raw: string;
  from: number;
  to: number;
  alt: string;
  url: string;
  width: number | null;
}

function clampWidth(width: number, maxWidth: number): number {
  const boundedMax = Math.max(MIN_IMAGE_WIDTH, maxWidth);
  return Math.max(MIN_IMAGE_WIDTH, Math.min(Math.round(width), boundedMax));
}

function getEditorContentMaxWidth(view: EditorView): number {
  const contentNode = view.dom.querySelector('.cm-content');
  if (!(contentNode instanceof HTMLElement)) return DEFAULT_MAX_IMAGE_WIDTH;
  return Math.max(MIN_IMAGE_WIDTH, Math.floor(contentNode.clientWidth - 8));
}

function sanitizeAltText(alt: string): string {
  return alt.replace(/[\[\]\(\)]/g, '').trim() || 'image';
}

export function normalizeTickerAssetUrl(url: string): string {
  if (!url.startsWith('ticker-asset://')) return url;
  return url.replace(/ /g, '%20');
}

export function buildMarkdownImageToken(args: { alt: string; url: string; width?: number | null }): string {
  const safeAlt = sanitizeAltText(args.alt);
  const safeUrl = normalizeTickerAssetUrl(args.url);

  if (typeof args.width === 'number') {
    const width = clampWidth(args.width, DEFAULT_MAX_IMAGE_WIDTH);
    return `![${safeAlt}](${safeUrl}){width=${width}}`;
  }

  return `![${safeAlt}](${safeUrl})`;
}

export function extractMarkdownImageUrls(markdownText: string): string[] {
  const urls: string[] = [];
  const regex = new RegExp(MARKDOWN_IMAGE_TOKEN_REGEX.source, 'g');

  for (const match of markdownText.matchAll(regex)) {
    if (match[2]) {
      urls.push(normalizeTickerAssetUrl(match[2]));
    }
  }

  return urls;
}

export function findImageTokens(text: string, offset = 0): MarkdownImageToken[] {
  const tokens: MarkdownImageToken[] = [];
  const regex = new RegExp(MARKDOWN_IMAGE_TOKEN_REGEX.source, 'g');

  let match: RegExpExecArray | null;
  while ((match = regex.exec(text)) !== null) {
    const raw = match[0];
    const alt = match[1] ?? 'image';
    const url = match[2];
    if (!url) continue;

    const parsedWidth = Number.parseInt(match[3] ?? '', 10);
    const width = Number.isFinite(parsedWidth) ? clampWidth(parsedWidth, DEFAULT_MAX_IMAGE_WIDTH) : null;

    tokens.push({
      raw,
      from: offset + match.index,
      to: offset + match.index + raw.length,
      alt,
      url: normalizeTickerAssetUrl(url),
      width,
    });
  }

  return tokens;
}

function imageDecorationForToken(token: MarkdownImageToken): Range<Decoration> {
  return Decoration.replace({
    widget: new MarkdownImageBlockWidget(token),
  }).range(token.from, token.to);
}

class MarkdownImageBlockWidget extends WidgetType {
  constructor(private readonly token: MarkdownImageToken) {
    super();
  }

  eq(other: MarkdownImageBlockWidget): boolean {
    return this.token.raw === other.token.raw;
  }

  toDOM(view: EditorView): HTMLElement {
    const wrapper = document.createElement('span');
    wrapper.className = 'cm-md-image-widget';
    wrapper.contentEditable = 'false';

    const image = document.createElement('img');
    image.className = 'cm-md-image-widget-image';
    image.src = this.token.url;
    image.alt = this.token.alt || 'image';
    if (this.token.width) {
      image.style.width = `${this.token.width}px`;
    }

    const handle = document.createElement('button');
    handle.type = 'button';
    handle.className = 'cm-md-image-resize-handle';
    handle.title = 'Resize image';
    handle.setAttribute('aria-label', 'Resize image');

    const startResize = (event: MouseEvent) => {
      event.preventDefault();
      event.stopPropagation();

      const startX = event.clientX;
      const baseWidth = this.token.width ?? image.getBoundingClientRect().width;
      let nextWidth = clampWidth(baseWidth, getEditorContentMaxWidth(view));
      image.style.width = `${nextWidth}px`;

      const onMouseMove = (moveEvent: MouseEvent) => {
        const delta = moveEvent.clientX - startX;
        nextWidth = clampWidth(baseWidth + delta, getEditorContentMaxWidth(view));
        image.style.width = `${nextWidth}px`;
      };

      const onMouseUp = () => {
        window.removeEventListener('mousemove', onMouseMove);
        window.removeEventListener('mouseup', onMouseUp);

        const replacement = buildMarkdownImageToken({
          alt: this.token.alt,
          url: this.token.url,
          width: nextWidth,
        });

        const current = view.state.doc.sliceString(this.token.from, this.token.to);
        if (current === replacement) return;

        view.dispatch({
          changes: {
            from: this.token.from,
            to: this.token.to,
            insert: replacement,
          },
        });
      };

      window.addEventListener('mousemove', onMouseMove);
      window.addEventListener('mouseup', onMouseUp);
    };

    handle.addEventListener('mousedown', startResize);

    wrapper.append(image);
    wrapper.append(handle);
    return wrapper;
  }
}

function buildImageDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const text = view.state.doc.toString();

  for (const token of findImageTokens(text)) {
    builder.add(token.from, token.to, Decoration.replace({ widget: new MarkdownImageBlockWidget(token) }));
  }

  return builder.finish();
}

function changedLineRanges(update: ViewUpdate): Array<{ from: number; to: number }> {
  const doc = update.state.doc;
  const ranges: Array<{ from: number; to: number }> = [];

  update.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    if (doc.length === 0) {
      ranges.push({ from: 0, to: 0 });
      return;
    }

    const fromLine = doc.lineAt(Math.min(fromB, doc.length));
    const toLine = doc.lineAt(Math.min(Math.max(fromB, toB), doc.length));
    ranges.push({
      from: fromLine.from,
      to: toLine.to,
    });
  });

  return mergeRanges(ranges);
}

function mergeRanges(ranges: Array<{ from: number; to: number }>): Array<{ from: number; to: number }> {
  if (ranges.length < 2) return ranges;

  const sorted = [...ranges].sort((a, b) => a.from - b.from || a.to - b.to);
  const merged: Array<{ from: number; to: number }> = [];

  for (const range of sorted) {
    const previous = merged[merged.length - 1];
    if (!previous || range.from > previous.to) {
      merged.push({ ...range });
      continue;
    }

    previous.to = Math.max(previous.to, range.to);
  }

  return merged;
}

function refreshChangedImageDecorations(decorations: DecorationSet, update: ViewUpdate): DecorationSet {
  let nextDecorations = decorations.map(update.changes);
  const additions: Array<Range<Decoration>> = [];

  for (const range of changedLineRanges(update)) {
    nextDecorations = nextDecorations.update({
      filterFrom: range.from,
      filterTo: range.to,
      filter: () => false,
    });

    const text = update.state.doc.sliceString(range.from, range.to);
    for (const token of findImageTokens(text, range.from)) {
      additions.push(imageDecorationForToken(token));
    }
  }

  if (additions.length === 0) return nextDecorations;
  return nextDecorations.update({ add: additions, sort: true });
}

const markdownImageWidgetPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildImageDecorations(view);
  }

  update(update: ViewUpdate): void {
    if (!update.docChanged) return;
    this.decorations = refreshChangedImageDecorations(this.decorations, update);
  }
}, {
  decorations: (value) => value.decorations,
  provide: (plugin) => EditorView.atomicRanges.of((view) => view.plugin(plugin)?.decorations ?? Decoration.none),
});

export const markdownImageWidgetExtension = markdownImageWidgetPlugin;
