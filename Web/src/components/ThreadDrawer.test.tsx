// @vitest-environment jsdom
import { act, createRef } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge } from '../types/bridge';
import type { StreamThreadJSON } from '../types/models';
import { useToastStore } from '../store/toastStore';
import { ThreadDrawer, type ThreadDrawerHandle } from './ThreadDrawer';

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

let root: Root;
const drawerRef = createRef<ThreadDrawerHandle>();

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

async function renderDrawer() {
  await act(async () => {
    root.render(
      <ThreadDrawer
        ref={drawerRef}
        streamId="stream-1"
        isOpen
        onRequestClose={() => {}}
      />,
    );
    await Promise.resolve();
  });
}

async function openListedThread() {
  await vi.waitFor(() => expect(document.querySelector('.thread-list-item')).not.toBeNull());
  await act(async () => {
    (document.querySelector('.thread-list-item') as HTMLButtonElement).click();
    await Promise.resolve();
  });
  await vi.waitFor(() => expect(document.querySelector('[aria-label="My note"]')).not.toBeNull());
}

function typeNote(value: string) {
  const note = document.querySelector('[aria-label="My note"]') as HTMLTextAreaElement;
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(note, value);
  note.dispatchEvent(new Event('input', { bubbles: true }));
}

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  useToastStore.getState().clearToasts();
  root = createRoot(document.querySelector('#root')!);
});

afterEach(async () => {
  await act(async () => root.unmount());
  vi.restoreAllMocks();
  useToastStore.getState().clearToasts();
  document.body.innerHTML = '';
});

describe('ThreadDrawer', () => {
  it('lists threads, opens one, and flushes its latest note', async () => {
    const save = vi.fn().mockResolvedValue({
      conflict: false,
      thread: thread({ revision: 3, workingText: 'Local work' }),
    });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type, payload) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      if (type === 'saveStreamThread') return save(payload);
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);

    await renderDrawer();
    expect(document.querySelector('.thread-list-anchor')?.textContent)
      .toBe('The MCU may draw too much power.');
    await openListedThread();

    await act(async () => {
      typeNote('Local work');
      await Promise.resolve();
    });
    await expect(drawerRef.current!.flush()).resolves.toBe(true);
    expect(save).toHaveBeenCalledWith(expect.objectContaining({
      streamId: 'stream-1',
      threadId: 'thread-1',
      workingText: 'Local work',
      baseRevision: 2,
    }));
    expect(document.querySelector('.thread-save-state')?.textContent).toBe('Saved');
  });

  it('keeps local text after a conflict and reloads only on request', async () => {
    const stored = thread({ revision: 8, workingText: 'Stored elsewhere' });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      if (type === 'saveStreamThread') return { conflict: true, thread: stored };
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);

    await renderDrawer();
    await openListedThread();
    await act(async () => {
      typeNote('Local work survives');
      await Promise.resolve();
    });

    await expect(drawerRef.current!.flush()).resolves.toBe(false);
    expect((document.querySelector('[aria-label="My note"]') as HTMLTextAreaElement).value)
      .toBe('Local work survives');
    expect(document.querySelector('.thread-save-warning')?.textContent)
      .toContain('changed elsewhere');

    await act(async () => {
      ([...document.querySelectorAll('button')]
        .find((button) => button.textContent === 'Reload stored note') as HTMLButtonElement).click();
    });
    expect((document.querySelector('[aria-label="My note"]') as HTMLTextAreaElement).value)
      .toBe('Stored elsewhere');
  });

  it('can resolve a conflict by saving the local note over the stored copy', async () => {
    const stored = thread({ revision: 8, workingText: 'Stored elsewhere' });
    const save = vi.fn()
      .mockResolvedValueOnce({ conflict: true, thread: stored })
      .mockResolvedValueOnce({
        conflict: false,
        thread: thread({ revision: 9, workingText: 'Local work survives' }),
      });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type, payload) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      if (type === 'saveStreamThread') return save(payload);
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);

    await renderDrawer();
    await openListedThread();
    await act(async () => {
      typeNote('Local work survives');
      await Promise.resolve();
    });
    await expect(drawerRef.current!.flush()).resolves.toBe(false);
    await act(async () => {
      ([...document.querySelectorAll('button')]
        .find((button) => button.textContent === 'Save my note instead') as HTMLButtonElement).click();
      await Promise.resolve();
    });

    await vi.waitFor(() => expect(document.querySelector('.thread-save-state')?.textContent).toBe('Saved'));
    expect(save).toHaveBeenLastCalledWith(expect.objectContaining({ baseRevision: 8 }));
    expect((document.querySelector('[aria-label="My note"]') as HTMLTextAreaElement).value)
      .toBe('Local work survives');
  });
});
