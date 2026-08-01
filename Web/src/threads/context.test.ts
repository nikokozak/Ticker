import { describe, expect, it } from 'vitest';
import { manifestCitations, parseThreadAISentFacts } from './context';

const receipt = {
  version: 1,
  kind: 'threadAI',
  requestId: 'request-3',
  anchor: { kind: 'stream', text: 'Start here.' },
  note: { sent: true, text: 'Check this.' },
  turns: { includedRequestIds: ['request-1', 'request-2'], totalAtSend: 2 },
  sourceContextMode: 'retrieved',
  sources: [{
    kind: 'passage', n: 1, sourceId: 'source-1', chunkId: 'chunk-1',
    page: 4, shortTitle: 'Manual',
  }],
};

const receiptV2 = {
  ...receipt,
  version: 2,
  anchor: { kind: 'stream', text: 'Start here.', from: 5, to: 16 },
  streamDocument: { sent: true, charCount: 1200 },
  pinned: [{
    kind: 'stream_quote', quote: 'Pinned Stream text.', from: 30, to: 49,
  }, {
    kind: 'pdf_quote', quote: 'Pinned PDF text.', sourceId: 'source-2',
    sourceName: 'Datasheet', highlightId: 'highlight-2', page: 12,
  }],
  profile: 'research',
};

describe('thread AI context receipts', () => {
  it('keeps stable history IDs and parses the exact host receipt', () => {
    const parsed = parseThreadAISentFacts(receipt);
    expect(parsed?.turns).toEqual({
      includedRequestIds: ['request-1', 'request-2'],
      totalAtSend: 2,
    });
    expect(parsed?.version).toBe(1);
    expect(parsed?.pinned).toEqual([]);
    expect(parsed?.streamDocument).toBeUndefined();
  });

  it('parses v2 primary range and pinned context without weakening v1', () => {
    expect(parseThreadAISentFacts(receiptV2)).toMatchObject({
      version: 2,
      anchor: { text: 'Start here.', from: 5, to: 16 },
      streamDocument: { sent: true, charCount: 1200 },
      pinned: receiptV2.pinned,
      profile: 'research',
    });
    expect(parseThreadAISentFacts({
      ...receiptV2,
      pinned: [{ kind: 'stream_quote' }, receiptV2.pinned[1]],
    })?.pinned).toEqual([receiptV2.pinned[1]]);
    for (const invalidPosition of [null, '', false, []]) {
      expect(parseThreadAISentFacts({
        ...receiptV2,
        anchor: { ...receiptV2.anchor, from: invalidPosition, to: 16 },
      })).toBe(null);
    }
    expect(parseThreadAISentFacts({
      ...receiptV2,
      pinned: [{ kind: 'stream_quote', quote: 'Bad range', from: '', to: 4 }],
    })?.pinned).toEqual([]);
    expect(parseThreadAISentFacts({ ...receiptV2, profile: 'unknown' })).toBe(null);
  });

  it('keeps released citation-array manifests readable', () => {
    const legacy = JSON.stringify([{ sourceId: 'source-1', chunkId: 'chunk-1', page: 4, shortTitle: 'Manual' }]);
    expect(manifestCitations(legacy)).toEqual([{
      n: 1, sourceId: 'source-1', chunkId: 'chunk-1', page: 4, shortTitle: 'Manual',
    }]);
    expect(manifestCitations(JSON.stringify(receipt))).toEqual(manifestCitations(legacy));
    expect(manifestCitations(JSON.stringify([{
      sourceId: 'source-1', chunkId: 'chunk-1', page: 0, shortTitle: 'Manual',
    }]))[0].page).toBe(1);
  });
});
