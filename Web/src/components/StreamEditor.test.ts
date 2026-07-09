import { describe, expect, it } from 'vitest';
import { documentAIErrorRecovery, nextSourceScope, wrapChallengeOutput } from './StreamEditor';

describe('nextSourceScope', () => {
  it('cycles auto to all to none to auto', () => {
    expect(nextSourceScope('auto')).toBe('all');
    expect(nextSourceScope('all')).toBe('none');
    expect(nextSourceScope('none')).toBe('auto');
  });
});

describe('wrapChallengeOutput', () => {
  it('quotes a single paragraph and tags the register', () => {
    expect(wrapChallengeOutput('Weak premise. What follows?')).toBe(
      '> Weak premise. What follows?\n\n*— Challenge*'
    );
  });

  it('quotes multi-paragraph output line by line', () => {
    expect(wrapChallengeOutput('First paragraph.\n\nSecond paragraph?')).toBe(
      '> First paragraph.\n> \n> Second paragraph?\n\n*— Challenge*'
    );
  });
});

describe('documentAIErrorRecovery', () => {
  it('restores cancelled output silently', () => {
    expect(documentAIErrorRecovery('original text', 'cancelled')).toEqual({
      restoreText: 'original text',
      silent: true,
    });
  });

  it('restores other errors with visible feedback', () => {
    expect(documentAIErrorRecovery('original text', 'rate_limited')).toEqual({
      restoreText: 'original text',
      silent: false,
    });
  });
});
