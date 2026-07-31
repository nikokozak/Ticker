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

describe('thread AI context receipts', () => {
  it('keeps stable history IDs and parses the exact host receipt', () => {
    expect(parseThreadAISentFacts(receipt)?.turns).toEqual({
      includedRequestIds: ['request-1', 'request-2'],
      totalAtSend: 2,
    });
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
