import type { DocumentAICitation } from '../types';

const CITATION_MARKER_PATTERN = /【(\d+)(?:\|([^】]*))?】/g;
const QUOTE_DELIMITERS = new Set(['"', '“', '”']);
const MAX_QUOTE_QUERY_LENGTH = 200;

export interface SwappedCitation {
  n: number;
  chunkId: string;
  sourceId: string;
  shortTitle: string;
}

export interface CitationMarkerSwapResult {
  text: string;
  swappedCitations: SwappedCitation[];
}

function pageLabel(citation: DocumentAICitation): string {
  const page = Number.isFinite(citation.page) ? Math.max(1, Math.round(citation.page)) : 1;
  return `p.${page}`;
}

function markdownLinkLabel(citation: DocumentAICitation, pageOnlyLabel: boolean): string {
  if (pageOnlyLabel) return pageLabel(citation);
  return `${citation.shortTitle.trim()} ${pageLabel(citation)}`.trim();
}

function escapeMarkdownLabel(label: string): string {
  return label
    .replace(/\\/g, '\\\\')
    .replace(/\]/g, '\\]');
}

function quoteFromMarker(rawQuote: string | undefined): string | null {
  if (!rawQuote) return null;

  const trimmed = rawQuote.trim();
  if (trimmed.length < 2) return null;

  const opening = trimmed[0];
  const closing = trimmed[trimmed.length - 1];
  if (!QUOTE_DELIMITERS.has(opening) || !QUOTE_DELIMITERS.has(closing)) {
    return null;
  }

  const quote = trimmed.slice(1, -1);
  return quote ? quote : null;
}

function appendLinkWithSpacing(output: string, link: string): string {
  if (output.length === 0) return link;

  const trailingHorizontalWhitespace = output.match(/[^\S\r\n]+$/)?.[0] ?? '';
  if (trailingHorizontalWhitespace) {
    const beforeWhitespace = output.slice(0, -trailingHorizontalWhitespace.length);
    if (beforeWhitespace.length === 0 || /[\r\n]$/.test(beforeWhitespace)) {
      return `${beforeWhitespace}${link}`;
    }
    return `${beforeWhitespace} ${link}`;
  }

  if (/\s$/.test(output)) return `${output}${link}`;
  return `${output} ${link}`;
}

export function buildCitationLink(
  citation: DocumentAICitation,
  options: { pageOnlyLabel?: boolean; quote?: string | null } = {}
): string {
  const page = Number.isFinite(citation.page) ? Math.max(1, Math.round(citation.page)) : 1;
  const label = escapeMarkdownLabel(markdownLinkLabel(citation, options.pageOnlyLabel === true));
  const quote = options.quote?.slice(0, MAX_QUOTE_QUERY_LENGTH);
  const quoteQuery = quote ? `&q=${encodeURIComponent(quote)}` : '';
  const url = `ticker-pdf://${citation.sourceId}?page=${page}&chunk=${encodeURIComponent(citation.chunkId)}${quoteQuery}`;
  return `[${label}](${url})`;
}

export function swapCitationMarkersWithMetadata(
  text: string,
  citations: DocumentAICitation[]
): CitationMarkerSwapResult {
  const byNumber = new Map<number, DocumentAICitation>();
  const sourceIds = new Set<string>();
  const swappedCitations: SwappedCitation[] = [];

  for (const citation of citations) {
    if (!Number.isInteger(citation.n) || citation.n <= 0) continue;
    if (!citation.sourceId || !citation.chunkId || !citation.shortTitle) continue;
    byNumber.set(citation.n, citation);
    sourceIds.add(citation.sourceId);
  }

  const pageOnlyLabel = sourceIds.size === 1;
  const markerPattern = new RegExp(CITATION_MARKER_PATTERN.source, 'g');
  let output = '';
  let lastIndex = 0;
  let previousSwappedChunkId: string | null = null;
  let match: RegExpExecArray | null;

  while ((match = markerPattern.exec(text)) !== null) {
    const markerNumber = match[1] ?? '';
    const quote = quoteFromMarker(match[2]);
    const markerStart = match.index;
    const markerEnd = markerStart + match[0].length;
    const between = text.slice(lastIndex, markerStart);
    const citation = byNumber.get(Number(markerNumber));
    if (!citation) {
      output += between;
      previousSwappedChunkId = null;
      lastIndex = markerEnd;
      continue;
    }

    const isAdjacentDuplicate =
      previousSwappedChunkId === citation.chunkId && between.trim().length === 0;

    if (!isAdjacentDuplicate) {
      output += between;
      output = appendLinkWithSpacing(
        output,
        buildCitationLink(citation, { pageOnlyLabel, quote })
      );

      swappedCitations.push({
        n: citation.n,
        chunkId: citation.chunkId,
        sourceId: citation.sourceId,
        shortTitle: citation.shortTitle,
      });
      previousSwappedChunkId = citation.chunkId;
    }

    lastIndex = markerEnd;
  }

  output += text.slice(lastIndex);

  return { text: output, swappedCitations };
}

export function swapCitationMarkers(text: string, citations: DocumentAICitation[]): string {
  return swapCitationMarkersWithMetadata(text, citations).text;
}

export function buildProvenanceLine(swappedCitations: SwappedCitation[]): string | null {
  if (swappedCitations.length === 0) return null;

  const bySource = new Map<string, { shortTitle: string; count: number; firstIndex: number }>();

  swappedCitations.forEach((citation, index) => {
    const key = citation.sourceId || citation.shortTitle;
    const existing = bySource.get(key);
    if (existing) {
      existing.count += 1;
      return;
    }
    bySource.set(key, {
      shortTitle: citation.shortTitle,
      count: 1,
      firstIndex: index,
    });
  });

  const consulted = [...bySource.values()]
    .sort((left, right) => right.count - left.count || left.firstIndex - right.firstIndex)
    .map((source) => `${source.shortTitle} (${source.count})`)
    .join(', ');

  return `*Consulted: ${consulted}*`;
}
