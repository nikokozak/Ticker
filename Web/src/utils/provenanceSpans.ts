import type { ProvenanceSpanJSON } from '../types';

function readString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function readOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function readInteger(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null;
}

function readSpan(value: unknown): ProvenanceSpanJSON | null {
  if (!value || typeof value !== 'object') return null;
  const candidate = value as Record<string, unknown>;
  const spanId = readString(candidate.spanId);
  const start = readInteger(candidate.start);
  const end = readInteger(candidate.end);
  const origin = readString(candidate.origin);
  const meta = readString(candidate.meta);
  const textHash = readString(candidate.textHash);
  const createdAt = readString(candidate.createdAt);

  if (!spanId || start === null || end === null || !origin || meta === null || !textHash || !createdAt) {
    return null;
  }

  return {
    spanId,
    start,
    end,
    origin,
    requestId: readOptionalString(candidate.requestId),
    sourceId: readOptionalString(candidate.sourceId),
    meta,
    textHash,
    createdAt,
  };
}

export function deserializeProvenanceSpans(value: unknown): ProvenanceSpanJSON[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const span = readSpan(item);
    return span ? [span] : [];
  });
}

export function serializeProvenanceSpans(spans: ProvenanceSpanJSON[]): ProvenanceSpanJSON[] {
  return spans.map((span) => {
    const serialized: ProvenanceSpanJSON = {
      spanId: span.spanId,
      start: span.start,
      end: span.end,
      origin: span.origin,
      meta: span.meta,
      textHash: span.textHash,
      createdAt: span.createdAt,
    };
    if (span.requestId) serialized.requestId = span.requestId;
    if (span.sourceId) serialized.sourceId = span.sourceId;
    return serialized;
  });
}
