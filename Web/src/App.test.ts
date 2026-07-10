import { describe, expect, it } from 'vitest';
import { shouldAcceptStreamLoaded } from './App';

describe('shouldAcceptStreamLoaded', () => {
  it('accepts only the pending correlated response', () => {
    expect(shouldAcceptStreamLoaded(2, 2)).toBe(true);
    expect(shouldAcceptStreamLoaded(1, 2)).toBe(false);
    expect(shouldAcceptStreamLoaded(2, null)).toBe(false);
  });

  it('accepts an uncorrelated native response only with no web load pending', () => {
    expect(shouldAcceptStreamLoaded(undefined, null)).toBe(true);
    expect(shouldAcceptStreamLoaded(undefined, 2)).toBe(false);
  });
});
