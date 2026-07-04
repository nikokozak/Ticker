import type { DocumentAICitation } from '../types';

const CITATION_MARKER_PATTERN = /【(\d+)】/g;

export function buildCitationLink(citation: DocumentAICitation): string {
  const page = Number.isFinite(citation.page) ? Math.max(1, Math.round(citation.page)) : 1;
  const label = citation.label
    .replace(/\\/g, '\\\\')
    .replace(/\]/g, '\\]');
  const url = `ticker-pdf://${citation.sourceId}?page=${page}&chunk=${encodeURIComponent(citation.chunkId)}`;
  return `[${label}](${url})`;
}

export function swapCitationMarkers(text: string, citations: DocumentAICitation[]): string {
  const byNumber = new Map<number, DocumentAICitation>();

  for (const citation of citations) {
    if (!Number.isInteger(citation.n) || citation.n <= 0) continue;
    if (!citation.sourceId || !citation.chunkId || !citation.label) continue;
    byNumber.set(citation.n, citation);
  }

  return text.replace(CITATION_MARKER_PATTERN, (_marker, markerNumber: string) => {
    const citation = byNumber.get(Number(markerNumber));
    return citation ? buildCitationLink(citation) : '';
  });
}
