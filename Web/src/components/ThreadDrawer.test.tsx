// @vitest-environment jsdom
import { act, createRef, type ComponentProps } from 'react';
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

async function renderDrawer(props: Partial<ComponentProps<typeof ThreadDrawer>> = {}) {
  await act(async () => {
    root.render(
      <ThreadDrawer
        ref={drawerRef}
        streamId="stream-1"
        isOpen
        onRequestClose={() => {}}
        {...props}
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

function typePrompt(value: string) {
  const prompt = document.querySelector('[aria-label="Ask in this thread"]') as HTMLTextAreaElement;
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(prompt, value);
  prompt.dispatchEvent(new Event('input', { bubbles: true }));
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

  it('streams a saved thread exchange without writing to the Stream', async () => {
    const sent: Array<{ type: string; payload?: Record<string, unknown> }> = [];
    vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);
    const endAI = vi.fn();

    await renderDrawer({ onBeginAI: () => true, onEndAI: endAI });
    await openListedThread();
    await act(async () => {
      typePrompt('What constraint follows?');
    });
    await act(async () => {
      (document.querySelector('.thread-prompt button[type="submit"]') as HTMLButtonElement).click();
      await Promise.resolve();
    });

    const request = sent.find((message) => message.type === 'thinkDocument');
    expect(request?.payload).toEqual(expect.objectContaining({
      streamId: 'stream-1',
      threadId: 'thread-1',
      query: 'What constraint follows?',
    }));
    const requestId = request?.payload?.requestId as string;
    const receipt = {
      version: 1,
      kind: 'threadAI',
      requestId,
      anchor: { kind: 'stream', text: 'The MCU may draw too much power.' },
      note: { sent: true, text: 'Check sleep current.' },
      turns: { includedRequestIds: [], totalAtSend: 0 },
      sourceContextMode: 'none',
      sources: [],
    };
    const exchange = {
      requestId,
      streamId: 'stream-1',
      threadId: 'thread-1',
      verb: 'thread',
      userInput: 'What constraint follows?',
      sourceManifest: JSON.stringify(receipt),
      responseRaw: 'Use the lower-power part.',
      model: 'provider/model',
      createdAt: new Date().toISOString(),
    };

    await act(async () => {
      bridge.receive({ type: 'threadAIContext', payload: { requestId, sentContext: receipt } });
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Use the lower-power part.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId, exchange, sentContext: receipt } });
    });

    expect(document.querySelector('.thread-assistant-turn')?.textContent)
      .toContain('Use the lower-power part.');
    expect(document.querySelector('.thread-sent-context')?.textContent)
      .toContain('Previous turns: 0 of 0');
    expect(sent.some((message) => message.type === 'saveRichStreamDocument')).toBe(false);
    expect(sent.some((message) => message.type === 'saveStreamDocument')).toBe(false);
    expect(endAI).toHaveBeenCalledTimes(1);
  });

  it('does not send while the visible note is unsaved', async () => {
    const sent: Array<{ type: string }> = [];
    vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      if (type === 'saveStreamThread') return new Promise(() => {});
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);

    await renderDrawer({ onBeginAI: () => true });
    await openListedThread();
    await act(async () => {
      typeNote('Still saving');
      typePrompt('Do not send this yet.');
    });

    const send = document.querySelector('.thread-prompt button[type="submit"]') as HTMLButtonElement;
    expect(send.disabled).toBe(true);
    send.click();
    await act(async () => {
      (document.querySelector('[aria-label="Ask in this thread"]') as HTMLTextAreaElement)
        .dispatchEvent(new KeyboardEvent('keydown', {
          key: 'Enter', metaKey: true, bubbles: true, cancelable: true,
        }));
    });
    expect(sent.some((message) => message.type === 'thinkDocument')).toBe(false);
  });

  it('ignores late chunks after cancel when a new thread request starts', async () => {
    const sent: Array<{ type: string; payload?: Record<string, unknown> }> = [];
    vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
    vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type) => {
      if (type === 'listStreamThreads') return { threads: [thread()] };
      if (type === 'loadStreamThread') return { thread: thread() };
      throw new Error(`Unexpected ${type}`);
    }) as typeof bridge.sendAsync);

    await renderDrawer({ onBeginAI: () => true, onEndAI: () => {} });
    await openListedThread();
    await act(async () => { typePrompt('First prompt'); });
    await act(async () => {
      (document.querySelector('.thread-prompt button[type="submit"]') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    const firstId = sent.find((message) => message.type === 'thinkDocument')?.payload?.requestId as string;
    await act(async () => {
      ([...document.querySelectorAll('.thread-prompt-actions button')]
        .find((button) => button.textContent === 'Stop') as HTMLButtonElement).click();
    });
    expect(sent).toContainEqual({ type: 'cancelDocumentAI', payload: { requestId: firstId } });
    expect((document.querySelector('[aria-label="Ask in this thread"]') as HTMLTextAreaElement).value)
      .toBe('First prompt');

    await act(async () => { typePrompt('Second prompt'); });
    await act(async () => {
      (document.querySelector('.thread-prompt button[type="submit"]') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    const requests = sent.filter((message) => message.type === 'thinkDocument');
    const secondId = requests[1].payload?.requestId as string;

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId: firstId, chunk: 'Stale reply.' } });
      bridge.receive({ type: 'documentAIChunk', payload: { requestId: secondId, chunk: 'Current reply.' } });
    });
    expect(document.querySelector('.thread-assistant-turn')?.textContent).toContain('Current reply.');
    expect(document.querySelector('.thread-assistant-turn')?.textContent).not.toContain('Stale reply.');
  });
});
