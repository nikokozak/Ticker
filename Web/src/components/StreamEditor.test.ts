import { describe, expect, it } from 'vitest';
import { nextSourceScope } from './StreamEditor';

describe('nextSourceScope', () => {
  it('cycles auto to all to none to auto', () => {
    expect(nextSourceScope('auto')).toBe('all');
    expect(nextSourceScope('all')).toBe('none');
    expect(nextSourceScope('none')).toBe('auto');
  });
});
