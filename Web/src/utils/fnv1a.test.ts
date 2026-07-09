import { describe, expect, it } from 'vitest';
import { fnv1a } from './fnv1a';

describe('fnv1a', () => {
  it('matches the shared vector', () => {
    expect(fnv1a('The quick brown fox')).toBe('ae4d67e2');
  });
});
