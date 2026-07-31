import { describe, expect, it, vi } from 'vitest';
import type { StreamThreadJSON } from '../types/models';
import { ThreadDraftSession, type ThreadSaveState } from './session';

const thread = (overrides: Partial<StreamThreadJSON> = {}): StreamThreadJSON => ({
  threadId: 'thread-1',
  streamId: 'stream-1',
  title: 'Power budget',
  workingText: 'Check sleep current.',
  anchorText: 'The MCU may draw too much power.',
  revision: 2,
  createdAt: new Date(0).toISOString(),
  updatedAt: new Date(0).toISOString(),
  ...overrides,
});

describe('ThreadDraftSession', () => {
  it('drains edits made while a save is in flight', async () => {
    let finishFirst!: (value: { conflict: boolean; thread: StreamThreadJSON }) => void;
    const save = vi.fn()
      .mockImplementationOnce(() => new Promise((resolve) => { finishFirst = resolve; }))
      .mockResolvedValueOnce({ conflict: false, thread: thread({ revision: 4, workingText: 'Second' }) });
    const session = new ThreadDraftSession({ thread: thread(), save });

    session.update({ title: 'Power budget', workingText: 'First' });
    const flushing = session.saveNow();
    await vi.waitFor(() => expect(save).toHaveBeenCalledTimes(1));
    session.update({ title: 'Power budget', workingText: 'Second' });
    finishFirst({ conflict: false, thread: thread({ revision: 3, workingText: 'First' }) });

    await expect(flushing).resolves.toBe(true);
    expect(save).toHaveBeenNthCalledWith(2, expect.objectContaining({
      workingText: 'Second',
      baseRevision: 3,
    }));
  });

  it('keeps the local draft on conflict until the user resolves it', async () => {
    const states: ThreadSaveState[] = [];
    const stored = thread({ revision: 7, workingText: 'Stored elsewhere' });
    const save = vi.fn().mockResolvedValue({ conflict: true, thread: stored });
    const session = new ThreadDraftSession({
      thread: thread(),
      save,
      onSaveStateChange: (state) => states.push(state),
    });

    session.update({ title: 'Power budget', workingText: 'Local work' });
    await expect(session.saveNow()).resolves.toBe(false);
    session.update({ title: 'Power budget', workingText: 'Still local' });
    await expect(session.saveNow()).resolves.toBe(false);
    expect(save).toHaveBeenCalledTimes(1);
    expect(states).toContain('conflict');
    expect(session.reloadStored()).toEqual(stored);
    expect(session.saveState).toBe('saved');
  });

  it('can explicitly save the local draft over the conflicting stored copy', async () => {
    const stored = thread({ revision: 7, workingText: 'Stored elsewhere' });
    const save = vi.fn()
      .mockResolvedValueOnce({ conflict: true, thread: stored })
      .mockResolvedValueOnce({
        conflict: false,
        thread: thread({ revision: 8, workingText: 'Local work' }),
      });
    const session = new ThreadDraftSession({ thread: thread(), save });

    session.update({ title: 'Power budget', workingText: 'Local work' });
    await expect(session.saveNow()).resolves.toBe(false);
    await expect(session.keepLocal()).resolves.toBe(true);
    expect(save).toHaveBeenLastCalledWith(expect.objectContaining({
      workingText: 'Local work',
      baseRevision: 7,
    }));
  });

  it('flushes inside the debounce window and reports transport failure', async () => {
    vi.useFakeTimers();
    try {
      const save = vi.fn().mockRejectedValue(new Error('offline'));
      const session = new ThreadDraftSession({ thread: thread(), save });
      session.update({ title: 'Power budget', workingText: 'Not yet stored' });

      await expect(session.saveNow()).resolves.toBe(false);
      expect(save).toHaveBeenCalledTimes(1);
      expect(session.saveState).toBe('error');
    } finally {
      vi.useRealTimers();
    }
  });
});
