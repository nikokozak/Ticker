import { describe, expect, it } from 'vitest';
import { computeAppendInsertion } from './appendInsertion';

describe('computeAppendInsertion', () => {
  it('inserts a fragment without a separator into an empty document', () => {
    expect(computeAppendInsertion(0, 'Captured note')).toEqual({
      from: 0,
      insert: 'Captured note',
      insertedEnd: 'Captured note'.length,
    });
  });

  it('prefixes a blank-line separator when the document has content', () => {
    expect(computeAppendInsertion(14, 'Captured note')).toEqual({
      from: 14,
      insert: '\n\nCaptured note',
      insertedEnd: 14 + '\n\nCaptured note'.length,
    });
  });
});
