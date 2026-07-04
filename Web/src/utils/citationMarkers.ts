import type { DocumentAICitation } from '../types';

const CITATION_MARKER_PATTERN = /【(\d+)】/g;

export interface SwappedCitation {
  n: number;
  chunkId: string;
  sourceId: string;
  label: string;
  sourceLabel: string;
}

export interface CitationMarkerSwapResult {
  text: string;
  swappedCitations: SwappedCitation[];
}

export function buildCitationLink(citation: DocumentAICitation): string {
  const page = Number.isFinite(citation.page) ? Math.max(1, Math.round(citation.page)) : 1;
  const label = citation.label
    .replace(/\\/g, '\\\\')
    .replace(/\]/g, '\\]');
  const url = `ticker-pdf://${citation.sourceId}?page=${page}&chunk=${encodeURIComponent(citation.chunkId)}`;
  return `[${label}](${url})`;
}

export function sourceLabelFromCitationLabel(label: string): string {
  const stripped = label.trim().replace(/\s+p\.?\s*\d+$/i, '').trim();
  return stripped || label.trim() || 'Source';
}

export function swapCitationMarkersWithMetadata(
  text: string,
  citations: DocumentAICitation[]
): CitationMarkerSwapResult {
  const byNumber = new Map<number, DocumentAICitation>();
  const swappedCitations: SwappedCitation[] = [];

  for (const citation of citations) {
    if (!Number.isInteger(citation.n) || citation.n <= 0) continue;
    if (!citation.sourceId || !citation.chunkId || !citation.label) continue;
    byNumber.set(citation.n, citation);
  }

  const nextText = text.replace(CITATION_MARKER_PATTERN, (_marker, markerNumber: string) => {
    const citation = byNumber.get(Number(markerNumber));
    if (!citation) return '';

    swappedCitations.push({
      n: citation.n,
      chunkId: citation.chunkId,
      sourceId: citation.sourceId,
      label: citation.label,
      sourceLabel: sourceLabelFromCitationLabel(citation.label),
    });
    return buildCitationLink(citation);
  });

  return { text: nextText, swappedCitations };
}

export function swapCitationMarkers(text: string, citations: DocumentAICitation[]): string {
  return swapCitationMarkersWithMetadata(text, citations).text;
}

export function buildProvenanceLine(swappedCitations: SwappedCitation[]): string | null {
  if (swappedCitations.length === 0) return null;

  const bySource = new Map<string, { label: string; count: number; firstIndex: number }>();

  swappedCitations.forEach((citation, index) => {
    const key = citation.sourceId || citation.sourceLabel;
    const existing = bySource.get(key);
    if (existing) {
      existing.count += 1;
      return;
    }
    bySource.set(key, {
      label: citation.sourceLabel,
      count: 1,
      firstIndex: index,
    });
  });

  const consulted = [...bySource.values()]
    .sort((left, right) => right.count - left.count || left.firstIndex - right.firstIndex)
    .map((source) => `${source.label} (${source.count})`)
    .join(', ');

  return `*Consulted: ${consulted}*`;
}
