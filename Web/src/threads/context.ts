import type { ConversationToolFailure, DocumentAICitation } from '../types/bridge';

export interface ThreadAISourceFact {
  kind: 'passage' | 'wholeSource';
  n?: number;
  sourceId: string;
  chunkId?: string;
  page?: number;
  shortTitle: string;
}

export interface ThreadAIPinnedFact {
  kind: 'stream_quote' | 'pdf_quote';
  quote: string;
  from?: number;
  to?: number;
  sourceId?: string;
  sourceName?: string;
  highlightId?: string;
  page?: number;
}

export interface ThreadAISentFacts {
  version: 1 | 2;
  kind: 'threadAI';
  requestId: string;
  anchor: {
    kind: 'stream' | 'pdf';
    text: string;
    from?: number;
    to?: number;
    sourceId?: string;
    sourceName?: string;
    highlightId?: string;
    page?: number;
  };
  streamDocument?: { sent: boolean; charCount: number };
  note: { sent: boolean; text?: string };
  turns: { includedRequestIds: string[]; totalAtSend: number };
  sourceContextMode: 'none' | 'passthrough' | 'retrieved' | 'unavailable';
  sources: ThreadAISourceFact[];
  pinned: ThreadAIPinnedFact[];
  profile?: 'research';
  updateBlock?: {
    before: string;
    after: string;
    applied?: boolean;
    failure?: ConversationToolFailure;
  };
}

function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

const updateBlockFailures = new Set<ConversationToolFailure>([
  'passage_changed',
  'partial_anchor',
  'surface_closed',
  'thread_mismatch',
  'apply_error',
]);

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

function nonnegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined;
}

function parsePinned(value: unknown): ThreadAIPinnedFact | null {
  const pin = object(value);
  if (!pin || (pin.kind !== 'stream_quote' && pin.kind !== 'pdf_quote')) return null;
  if (typeof pin.quote !== 'string' || !pin.quote) return null;
  const from = nonnegativeInteger(pin.from);
  const to = nonnegativeInteger(pin.to);
  if ((from === undefined) !== (to === undefined) || (from !== undefined && to! < from)) return null;
  return {
    kind: pin.kind,
    quote: pin.quote,
    from,
    to,
    sourceId: optionalString(pin.sourceId),
    sourceName: optionalString(pin.sourceName),
    highlightId: optionalString(pin.highlightId),
    page: pageNumber(pin.page),
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
  const streamDocument = object(receipt?.streamDocument);
  const updateBlock = object(receipt?.updateBlock);
  if ((receipt?.version !== 1 && receipt?.version !== 2)
    || receipt.kind !== 'threadAI' || !anchor || !note || !turns) return null;
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
  const anchorFrom = nonnegativeInteger(anchor.from);
  const anchorTo = nonnegativeInteger(anchor.to);
  if ((anchorFrom === undefined) !== (anchorTo === undefined)
    || (anchorFrom !== undefined && anchorTo! < anchorFrom)) return null;
  const streamCharCount = nonnegativeInteger(streamDocument?.charCount);
  if (receipt.version === 2 && (!streamDocument
    || typeof streamDocument.sent !== 'boolean'
    || streamCharCount === undefined)) return null;
  const pinned = Array.isArray(receipt.pinned)
    ? receipt.pinned.flatMap((pin) => parsePinned(pin) ?? [])
    : [];
  if (receipt.version === 2 && !Array.isArray(receipt.pinned)) return null;
  if (receipt.profile !== undefined && receipt.profile !== 'research') return null;
  if (receipt.updateBlock !== undefined && (!updateBlock
    || typeof updateBlock.before !== 'string'
    || typeof updateBlock.after !== 'string')) return null;
  const updateApplied = updateBlock?.applied;
  const updateFailure = updateBlock?.failure;
  if (updateApplied !== undefined && typeof updateApplied !== 'boolean') return null;
  if (updateFailure != null && (typeof updateFailure !== 'string'
    || !updateBlockFailures.has(updateFailure as ConversationToolFailure))) return null;
  if ((updateApplied === true && updateFailure != null)
    || (updateApplied === false && updateFailure == null)
    || (updateApplied === undefined && updateFailure != null)) return null;

  return {
    version: receipt.version,
    kind: 'threadAI',
    requestId: receipt.requestId,
    anchor: {
      kind: anchor.kind,
      text: anchor.text,
      from: anchorFrom,
      to: anchorTo,
      sourceId: optionalString(anchor.sourceId),
      sourceName: optionalString(anchor.sourceName),
      highlightId: optionalString(anchor.highlightId),
      page: positiveInteger(anchor.page),
    },
    streamDocument: receipt.version === 2
      ? { sent: streamDocument!.sent as boolean, charCount: streamCharCount! }
      : undefined,
    note: {
      sent: note.sent,
      text: optionalString(note.text),
    },
    turns: { includedRequestIds, totalAtSend },
    sourceContextMode: receipt.sourceContextMode as ThreadAISentFacts['sourceContextMode'],
    sources: Array.isArray(receipt.sources)
      ? receipt.sources.flatMap((source) => parseSource(source) ?? [])
      : [],
    pinned,
    profile: receipt.profile,
    updateBlock: updateBlock ? {
      before: updateBlock.before as string,
      after: updateBlock.after as string,
      applied: updateApplied as boolean | undefined,
      failure: updateFailure == null ? undefined : updateFailure as ConversationToolFailure,
    } : undefined,
  };
}

export function threadAIReceiptWithUpdateResult(
  value: string,
  before: string,
  failure?: ConversationToolFailure,
): string | null {
  let receipt: Record<string, unknown> | null;
  try { receipt = object(JSON.parse(value) as unknown); } catch { return null; }
  const updateBlock = object(receipt?.updateBlock);
  if (!receipt || !updateBlock || typeof updateBlock.after !== 'string') return null;
  return JSON.stringify({
    ...receipt,
    updateBlock: {
      ...updateBlock,
      before,
      applied: failure === undefined,
      failure: failure ?? null,
    },
  });
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

/** Accepts released citation arrays and both thread receipt versions. */
export function manifestCitations(sourceManifest: string): DocumentAICitation[] {
  let parsed: unknown;
  try { parsed = JSON.parse(sourceManifest) as unknown; } catch { return []; }
  if (Array.isArray(parsed)) return parsed.flatMap((entry, index) => citation(entry, index + 1) ?? []);
  return parseThreadAISentFacts(parsed)?.sources.flatMap(
    (entry, index) => citation(entry, index + 1) ?? [],
  ) ?? [];
}
