import { RangeSetBuilder, type Range } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from '@codemirror/view';

const MARKDOWN_IMAGE_TOKEN_REGEX = /!\[([^\]]*)\]\((ticker-asset:\/\/[^)]+)\)(?:\{width=(\d{2,4})\})?/g;
const MIN_IMAGE_WIDTH = 120;
const DEFAULT_MAX_IMAGE_WIDTH = 920;
const DEFAULT_ESTIMATED_IMAGE_WIDTH = 360;
const DEFAULT_ESTIMATED_IMAGE_RATIO = 0.625;
const MIN_ESTIMATED_IMAGE_HEIGHT = 96;

const renderedImageSizesByURL = new Map<string, { width: number; height: number }>();

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

function clampEstimatedHeight(height: number): number {
  if (!Number.isFinite(height) || height <= 0) return MIN_ESTIMATED_IMAGE_HEIGHT;
  return Math.max(MIN_ESTIMATED_IMAGE_HEIGHT, Math.round(height));
}

export function normalizeTickerAssetUrl(url: string): string {
  if (!url.startsWith('ticker-asset://')) return url;
  return url.replace(/ /g, '%20');
}

export function clearMarkdownImageHeightCacheForTests(): void {
  renderedImageSizesByURL.clear();
}

export function rememberMarkdownImageRenderedSize(url: string, renderedWidth: number, renderedHeight: number): void {
  if (!Number.isFinite(renderedWidth) || !Number.isFinite(renderedHeight) || renderedWidth <= 0 || renderedHeight <= 0) {
    return;
  }

  renderedImageSizesByURL.set(normalizeTickerAssetUrl(url), {
    width: Math.max(1, Math.round(renderedWidth)),
    height: clampEstimatedHeight(renderedHeight),
  });
}

export function estimateMarkdownImageHeight(args: { url: string; width: number | null }): number {
  const cached = renderedImageSizesByURL.get(normalizeTickerAssetUrl(args.url));
  if (cached) {
    const targetWidth = args.width ? clampWidth(args.width, DEFAULT_MAX_IMAGE_WIDTH) : cached.width;
    return clampEstimatedHeight((cached.height * targetWidth) / cached.width);
  }

  const fallbackWidth = args.width ? clampWidth(args.width, DEFAULT_MAX_IMAGE_WIDTH) : DEFAULT_ESTIMATED_IMAGE_WIDTH;
  return clampEstimatedHeight(fallbackWidth * DEFAULT_ESTIMATED_IMAGE_RATIO);
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

  get estimatedHeight(): number {
    return estimateMarkdownImageHeight({ url: this.token.url, width: this.token.width });
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

    const handle = document.createElement('button');
    handle.type = 'button';
    handle.className = 'cm-md-image-resize-handle';
    handle.title = 'Resize image';
    handle.setAttribute('aria-label', 'Resize image');

    wrapper.append(image);
    wrapper.append(handle);
    this.configureDOM(wrapper, image, handle, view);
    return wrapper;
  }

  updateDOM(dom: HTMLElement, view: EditorView): boolean {
    if (!dom.classList.contains('cm-md-image-widget')) return false;

    const image = dom.querySelector('.cm-md-image-widget-image');
    const handle = dom.querySelector('.cm-md-image-resize-handle');
    if (!(image instanceof HTMLImageElement) || !(handle instanceof HTMLButtonElement)) return false;

    this.configureDOM(dom, image, handle, view);
    return true;
  }

  private configureDOM(
    wrapper: HTMLElement,
    image: HTMLImageElement,
    handle: HTMLButtonElement,
    view: EditorView,
  ): void {
    wrapper.dataset.imageUrl = this.token.url;

    if (image.getAttribute('src') !== this.token.url) {
      image.src = this.token.url;
    }
    image.alt = this.token.alt || 'image';
    if (this.token.width) {
      image.style.width = `${this.token.width}px`;
    } else {
      image.style.removeProperty('width');
    }

    image.onload = () => this.scheduleRenderedSizeMeasure(view, wrapper, image);
    if (image.complete && image.naturalWidth > 0) {
      this.scheduleRenderedSizeMeasure(view, wrapper, image);
    }

    handle.onmousedown = (event) => {
      this.startResize(event, view, image);
    };
  }

  private scheduleRenderedSizeMeasure(view: EditorView, wrapper: HTMLElement, image: HTMLImageElement): void {
    view.requestMeasure({
      key: wrapper,
      read: () => ({
        width: image.getBoundingClientRect().width,
        height: wrapper.getBoundingClientRect().height,
      }),
      write: (size) => {
        rememberMarkdownImageRenderedSize(this.token.url, size.width, size.height);
      },
    });
  }

  private startResize(event: MouseEvent, view: EditorView, image: HTMLImageElement): void {
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
  }
}

function buildImageDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();

  for (const range of visibleLineRanges(view)) {
    const text = view.state.doc.sliceString(range.from, range.to);
    for (const token of findImageTokens(text, range.from)) {
      const decoration = imageDecorationForToken(token);
      builder.add(decoration.from, decoration.to, decoration.value);
    }
  }

  return builder.finish();
}

function visibleLineRanges(view: EditorView): Array<{ from: number; to: number }> {
  const doc = view.state.doc;
  const ranges: Array<{ from: number; to: number }> = [];

  for (const visibleRange of view.visibleRanges) {
    const fromLine = doc.lineAt(Math.min(visibleRange.from, doc.length));
    const toLine = doc.lineAt(Math.min(visibleRange.to, doc.length));
    ranges.push({
      from: fromLine.from,
      to: toLine.to,
    });
  }

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

const markdownImageWidgetPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;

  constructor(view: EditorView) {
    this.decorations = buildImageDecorations(view);
  }

  update(update: ViewUpdate): void {
    if (update.docChanged || update.viewportChanged) {
      this.decorations = buildImageDecorations(update.view);
    }
  }
}, {
  decorations: (value) => value.decorations,
  provide: (plugin) => EditorView.atomicRanges.of((view) => view.plugin(plugin)?.decorations ?? Decoration.none),
});

export const markdownImageWidgetExtension = markdownImageWidgetPlugin;
