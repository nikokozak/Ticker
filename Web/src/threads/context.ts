import type { DocumentAICitation } from '../types/bridge';

export interface ThreadAISourceFact {
  kind: 'passage' | 'wholeSource';
  n?: number;
  sourceId: string;
  chunkId?: string;
  page?: number;
  shortTitle: string;
}

export interface ThreadAISentFacts {
  version: 1;
  kind: 'threadAI';
  requestId: string;
  anchor: {
    kind: 'stream' | 'pdf';
    text: string;
    sourceId?: string;
    sourceName?: string;
    highlightId?: string;
    page?: number;
  };
  note: { sent: boolean; text?: string };
  turns: { includedRequestIds: string[]; totalAtSend: number };
  sourceContextMode: 'none' | 'passthrough' | 'retrieved' | 'unavailable';
  sources: ThreadAISourceFact[];
}

function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function positiveInteger(value: unknown): number | undefined {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : undefined;
}

function pageNumber(value: unknown): number | undefined {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(1, Math.round(number)) : undefined;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value ? value : undefined;
}

function parseSource(value: unknown): ThreadAISourceFact | null {
  const source = object(value);
  if (!source) return null;
  const kind = source.kind === 'wholeSource' ? 'wholeSource' : 'passage';
  const sourceId = optionalString(source.sourceId);
  const shortTitle = optionalString(source.shortTitle);
  if (!sourceId || !shortTitle) return null;
  return {
    kind,
    sourceId,
    shortTitle,
    n: positiveInteger(source.n),
    chunkId: optionalString(source.chunkId),
    page: pageNumber(source.page),
  };
}

export function parseThreadAISentFacts(value: unknown): ThreadAISentFacts | null {
  let parsed = value;
  if (typeof parsed === 'string') {
    try { parsed = JSON.parse(parsed) as unknown; } catch { return null; }
  }

  const receipt = object(parsed);
  const anchor = object(receipt?.anchor);
  const note = object(receipt?.note);
  const turns = object(receipt?.turns);
  if (receipt?.version !== 1 || receipt.kind !== 'threadAI' || !anchor || !note || !turns) return null;
  if (typeof receipt.requestId !== 'string' || typeof anchor.text !== 'string') return null;
  if (anchor.kind !== 'stream' && anchor.kind !== 'pdf') return null;
  if (typeof note.sent !== 'boolean' || !Array.isArray(turns.includedRequestIds)) return null;
  const includedRequestIds = turns.includedRequestIds.filter(
    (requestId): requestId is string => typeof requestId === 'string',
  );
  if (includedRequestIds.length !== turns.includedRequestIds.length) return null;
  const totalAtSend = Number(turns.totalAtSend);
  if (!Number.isInteger(totalAtSend) || totalAtSend < includedRequestIds.length) return null;
  const modes = new Set(['none', 'passthrough', 'retrieved', 'unavailable']);
  if (typeof receipt.sourceContextMode !== 'string' || !modes.has(receipt.sourceContextMode)) return null;

  return {
    version: 1,
    kind: 'threadAI',
    requestId: receipt.requestId,
    anchor: {
      kind: anchor.kind,
      text: anchor.text,
      sourceId: optionalString(anchor.sourceId),
      sourceName: optionalString(anchor.sourceName),
      highlightId: optionalString(anchor.highlightId),
      page: positiveInteger(anchor.page),
    },
    note: {
      sent: note.sent,
      text: optionalString(note.text),
    },
    turns: { includedRequestIds, totalAtSend },
    sourceContextMode: receipt.sourceContextMode as ThreadAISentFacts['sourceContextMode'],
    sources: Array.isArray(receipt.sources)
      ? receipt.sources.flatMap((source) => parseSource(source) ?? [])
      : [],
  };
}

function citation(value: unknown, fallbackNumber: number): DocumentAICitation | null {
  const source = object(value);
  if (!source) return null;
  const n = positiveInteger(source.n) ?? fallbackNumber;
  const page = pageNumber(source.page);
  const chunkId = optionalString(source.chunkId);
  const sourceId = optionalString(source.sourceId);
  const shortTitle = optionalString(source.shortTitle);
  return n && page && chunkId && sourceId && shortTitle
    ? { n, page, chunkId, sourceId, shortTitle }
    : null;
}

/** Accepts both released citation arrays and the v1 thread receipt object. */
export function manifestCitations(sourceManifest: string): DocumentAICitation[] {
  let parsed: unknown;
  try { parsed = JSON.parse(sourceManifest) as unknown; } catch { return []; }
  if (Array.isArray(parsed)) return parsed.flatMap((entry, index) => citation(entry, index + 1) ?? []);
  return parseThreadAISentFacts(parsed)?.sources.flatMap(
    (entry, index) => citation(entry, index + 1) ?? [],
  ) ?? [];
}
