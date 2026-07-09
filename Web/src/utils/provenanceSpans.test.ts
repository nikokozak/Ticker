import { describe, expect, it } from 'vitest';
import { deserializeProvenanceSpans, serializeProvenanceSpans } from './provenanceSpans';

describe('provenance span JSON helpers', () => {
  it('round-trips valid spans and drops malformed rows', () => {
    const spans = deserializeProvenanceSpans([
      {
        spanId: 'span-1',
        start: 1,
        end: 4,
        origin: 'ai',
        requestId: 'request-1',
        meta: '{}',
        textHash: 'ae4d67e2',
        createdAt: '2026-07-08T00:00:00Z',
      },
      { spanId: 'bad', start: 'nope' },
    ]);

    expect(spans).toEqual([
      {
        spanId: 'span-1',
        start: 1,
        end: 4,
        origin: 'ai',
        requestId: 'request-1',
        sourceId: undefined,
        meta: '{}',
        textHash: 'ae4d67e2',
        createdAt: '2026-07-08T00:00:00Z',
      },
    ]);
    expect(serializeProvenanceSpans(spans)).toEqual([
      {
        spanId: 'span-1',
        start: 1,
        end: 4,
        origin: 'ai',
        requestId: 'request-1',
        meta: '{}',
        textHash: 'ae4d67e2',
        createdAt: '2026-07-08T00:00:00Z',
      },
    ]);
  });
});
