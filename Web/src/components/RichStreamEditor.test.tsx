// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge, type WebToSwiftBridgeMessage } from '../types/bridge';
import type { Stream } from '../types/models';
import { DocumentSession } from '../richtext/session';
import { useToastStore } from '../store/toastStore';
import { fnv1a } from '../utils/fnv1a';
import { RichStreamEditor } from './RichStreamEditor';

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  const empty = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const none = () => Object.assign([] as unknown[], { item: () => null });
  for (const proto of [Range.prototype, Element.prototype, Text.prototype] as Array<{ getClientRects?: unknown; getBoundingClientRect?: unknown }>) {
    proto.getClientRects ??= none;
    proto.getBoundingClientRect ??= empty;
  }
});

const stream: Stream = {
  id: 'stream-1',
  title: 'Test',
  sourceScope: 'auto',
  sources: [],
  document: {
    streamId: 'stream-1',
    markdown: 'Original paragraph.',
    revision: 1,
    scrollOffset: 0,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
  },
  spans: [],
  marginNotes: [],
  createdAt: new Date(0).toISOString(),
  updatedAt: new Date(0).toISOString(),
};

let root: Root | null = null;
let sent: WebToSwiftBridgeMessage[] = [];

const editor = () => document.querySelector('.ProseMirror') as HTMLElement;

async function click(label: string) {
  const button = [...document.querySelectorAll('button')]
    .find((candidate) => candidate.getAttribute('aria-label') === label);
  expect(button, `Expected ${label} button`).toBeDefined();
  await act(async () => {
    (button as HTMLButtonElement).click();
    await Promise.resolve();
    await Promise.resolve();
  });
}

function activeRequestId(): string {
  const messages = sent.filter((candidate) => candidate.type === 'thinkDocument');
  const message = messages[messages.length - 1];
  expect(message, 'thinkDocument was not sent').toBeDefined();
  return String(message?.payload?.requestId);
}

function lastSent(): WebToSwiftBridgeMessage | undefined {
  return sent[sent.length - 1];
}

beforeEach(async () => {
  document.body.innerHTML = '<div id="root"></div>';
  useToastStore.getState().clearToasts();
  sent = [];
  vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
  vi.spyOn(bridge, 'sendAsync').mockImplementation(
    (async () => ({ revision: 2 })) as typeof bridge.sendAsync,
  );
  root = createRoot(document.querySelector('#root')!);
  await act(async () => {
    root!.render(<RichStreamEditor stream={stream} onBack={() => {}} onDelete={() => {}} />);
  });
});

afterEach(async () => {
  await act(async () => {
    root?.unmount();
    await Promise.resolve();
  });
  root = null;
  useToastStore.getState().clearToasts();
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

describe('RichStreamEditor document AI', () => {
  it('keeps a reply streamed in several chunks to one undo step', async () => {
    await click('Develop with AI');
    const requestId = activeRequestId();
    expect(editor().getAttribute('contenteditable')).toBe('false');
    expect((document.querySelector('[aria-label="Stop document AI"]') as HTMLButtonElement).disabled)
      .toBe(false);
    expect(lastSent()).toMatchObject({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: 'stream-1',
        query: 'Original paragraph.',
        sourceScope: 'auto',
        verb: 'develop',
        imageURLs: [],
      },
    });
    expect(lastSent()?.payload)
      .toHaveProperty('context', undefined);

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'A ' } });
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: '**streamed** ' } });
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'reply.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });

    expect(editor().textContent).toBe('A streamed reply.');
    expect(editor().getAttribute('contenteditable')).toBe('true');
    await act(async () => {
      editor().dispatchEvent(new KeyboardEvent('keydown', {
        key: 'z', ctrlKey: true, bubbles: true, cancelable: true,
      }));
    });
    expect(editor().textContent).toBe('Original paragraph.');
  });

  it('restores the text when the reply is only whitespace', async () => {
    // The AI answering with nothing usable must not cost the user the paragraph it
    // was asked about. Every chunk replaces the target range, so by the time the
    // reply turns out to be empty the original is already gone from the document.
    await click('Develop with AI');
    const requestId = activeRequestId();

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: '   \n  ' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });

    expect(editor().textContent).toBe('Original paragraph.');
    expect(useToastStore.getState().toasts.map((toast) => toast.message))
      .toEqual(['AI returned empty output.']);
  });

  it('stops highlighting once the reply has landed', async () => {
    // The highlight says "the AI is writing here". Left behind, it says it forever.
    await click('Develop with AI');
    const requestId = activeRequestId();

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'A reply.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });

    expect(document.querySelector('.richtext-ai-written')).toBe(null);
  });

  it('saves provenance over the reply text rather than its markdown', async () => {
    vi.useFakeTimers();
    try {
      await click('Develop with AI');
      const requestId = activeRequestId();

      await act(async () => {
        bridge.receive({
          type: 'documentModelSelected',
          payload: { requestId, modelId: 'provider/model' },
        });
        bridge.receive({
          type: 'documentAIChunk',
          payload: { requestId, chunk: '**Bold** reply.' },
        });
        bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
        await vi.advanceTimersByTimeAsync(400);
      });

      const saves = vi.mocked(bridge.sendAsync).mock.calls
        .filter(([type]) => type === 'saveStreamDocument');
      expect(saves).toHaveLength(1);
      expect(saves[0]?.[1]).toMatchObject({
        markdown: '**Bold** reply.',
        spans: [{
          start: 1,
          end: 12,
          origin: 'ai',
          requestId,
          meta: JSON.stringify({ model: 'provider/model', verb: 'develop' }),
          textHash: fnv1a('Bold reply.'),
        }],
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('swaps citation markers inside the streamed reply undo', async () => {
    vi.useFakeTimers();
    try {
      await click('Develop with AI');
      const requestId = activeRequestId();

      await act(async () => {
        bridge.receive({
          type: 'documentAIChunk',
          payload: { requestId, chunk: 'Supported claim【1】.' },
        });
        await vi.advanceTimersByTimeAsync(1_000);
        bridge.receive({
          type: 'documentAIComplete',
          payload: {
            requestId,
            citations: [{
              n: 1,
              chunkId: 'chunk-1',
              sourceId: 'source-1',
              page: 3,
              shortTitle: 'Paper',
            }],
          },
        });
      });

      expect(editor().textContent).not.toContain('【1】');
      expect(editor().querySelector('a')?.getAttribute('href'))
        .toBe('ticker-pdf://source-1?page=3&chunk=chunk-1');
      await act(async () => {
        editor().dispatchEvent(new KeyboardEvent('keydown', {
          key: 'z', ctrlKey: true, bubbles: true, cancelable: true,
        }));
      });
      expect(editor().textContent).toBe('Original paragraph.');
    } finally {
      vi.useRealTimers();
    }
  });

  it.each([
    ['none', 'From model knowledge.'],
    ['unavailable', 'Source retrieval unavailable — answered from model knowledge.'],
  ] as const)('records %s source context below the reply', async (sourceContextMode, line) => {
    await click('Develop with AI');
    const requestId = activeRequestId();

    await act(async () => {
      bridge.receive({
        type: 'documentAIChunk',
        payload: { requestId, chunk: 'A reply.' },
      });
      bridge.receive({
        type: 'documentAIComplete',
        payload: { requestId, sourceContextMode },
      });
    });

    expect([...editor().querySelectorAll('em')].map((node) => node.textContent))
      .toContain(line);
  });

  it('gives the document back when a conflict interrupts the stream', async () => {
    // The lock is released by the stream's own done(). A path that cancels from
    // somewhere else and forgets it leaves the user unable to type at all, in the
    // one situation where they most need to — their work is unsaved.
    await click('Develop with AI');
    const requestId = activeRequestId();
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Half a re' } });
      bridge.receive({
        type: 'streamDocumentConflict',
        payload: {
          streamId: 'stream-1',
          markdown: 'Original paragraph.\n\nfrom elsewhere',
          revision: 2,
          spans: [],
          pendingAppends: [],
        },
      });
    });

    expect(editor().getAttribute('contenteditable'), 'the editor was left read-only').toBe('true');
  });

  it('ignores a chunk for a stale request', async () => {
    await click('Develop with AI');
    const requestId = activeRequestId();

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId: 'stale', chunk: 'Wrong.' } });
    });
    expect(editor().textContent).toBe('Original paragraph.');

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Right.' } });
    });
    expect(editor().textContent).toBe('Right.');
    await click('Stop document AI');
  });

  it('uses selected text instead of the whole paragraph', async () => {
    const text = editor().querySelector('p')!.firstChild!;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 'Original'.length);
    editor().focus();
    window.getSelection()!.removeAllRanges();
    window.getSelection()!.addRange(range);
    await act(async () => {
      document.dispatchEvent(new Event('selectionchange'));
      bridge.receive({ type: 'getEditorSelection', payload: { requestId: 'selection-1' } });
    });
    expect(lastSent()).toEqual({
      type: 'editorSelection',
      payload: { requestId: 'selection-1', text: 'Original' },
    });

    await click('Develop with AI');
    const messages = sent.filter((candidate) => candidate.type === 'thinkDocument');
    const message = messages[messages.length - 1];
    expect(message?.payload?.query).toBe('Original');
    await click('Stop document AI');
  });

  it('cancels the host request and restores the original text', async () => {
    await click('Develop with AI');
    const requestId = activeRequestId();
    expect(editor().getAttribute('contenteditable')).toBe('false');
    await act(async () => {
      bridge.receive({
        type: 'documentAIChunk',
        payload: { requestId, chunk: '## Partial reply\n\nSecond block.' },
      });
    });

    await click('Stop document AI');

    expect(editor().textContent).toBe('Original paragraph.');
    expect(editor().getAttribute('contenteditable')).toBe('true');
    expect(lastSent()).toMatchObject({
      type: 'cancelDocumentAI',
      payload: { requestId },
    });
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Too late.' } });
    });
    expect(editor().textContent).toBe('Original paragraph.');
  });

  it('reports a real error, while cancellation stays silent', async () => {
    await click('Develop with AI');
    let requestId = activeRequestId();
    expect(editor().getAttribute('contenteditable')).toBe('false');
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Partial reply.' } });
      bridge.receive({
        type: 'documentAIError',
        payload: { requestId, error: 'Provider broke.', errorCode: 'upstream_error' },
      });
    });

    expect(editor().textContent).toBe('Original paragraph.');
    expect(editor().getAttribute('contenteditable')).toBe('true');
    expect(useToastStore.getState().toasts.map((toast) => toast.message)).toEqual(['Provider broke.']);

    useToastStore.getState().clearToasts();
    await click('Develop with AI');
    requestId = activeRequestId();
    expect(editor().getAttribute('contenteditable')).toBe('false');
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Another partial.' } });
      bridge.receive({
        type: 'documentAIError',
        payload: { requestId, error: 'Cancelled', errorCode: 'cancelled' },
      });
    });

    expect(editor().textContent).toBe('Original paragraph.');
    expect(editor().getAttribute('contenteditable')).toBe('true');
    expect(useToastStore.getState().toasts).toEqual([]);
  });

  it('does not save a half-written stream', async () => {
    vi.useFakeTimers();
    try {
      await click('Develop with AI');
      const requestId = activeRequestId();
      await act(async () => {
        bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Half ' } });
        bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'written.' } });
        await vi.advanceTimersByTimeAsync(1_000);
      });

      expect(vi.mocked(bridge.sendAsync).mock.calls
        .filter(([type]) => type === 'saveStreamDocument')).toHaveLength(0);
      await act(async () => {
        bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
        await vi.advanceTimersByTimeAsync(400);
      });
      expect(vi.mocked(bridge.sendAsync).mock.calls
        .filter(([type]) => type === 'saveStreamDocument')).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('does not start after leaving while the preflight save is still draining', async () => {
    let release!: (saved: boolean) => void;
    const draining = new Promise<boolean>((resolve) => { release = resolve; });
    vi.spyOn(DocumentSession.prototype, 'saveNow').mockReturnValue(draining);
    vi.spyOn(DocumentSession.prototype, 'destroy').mockResolvedValue(true);

    await click('Develop with AI');
    await act(async () => {
      (document.querySelector('.back-button') as HTMLButtonElement).click();
      release(true);
      await draining;
      await Promise.resolve();
    });

    expect(sent.filter((message) => message.type === 'thinkDocument')).toHaveLength(0);
  });

  it('reflects model and operation updates for only the active request', async () => {
    await click('Develop with AI');
    const requestId = activeRequestId();
    await act(async () => {
      bridge.receive({
        type: 'documentModelSelected',
        payload: { requestId: 'stale', modelId: 'wrong' },
      });
      bridge.receive({
        type: 'documentModelSelected',
        payload: { requestId, modelId: 'provider/model' },
      });
    });
    expect(document.querySelector('[aria-label="Stop document AI"]')?.getAttribute('title'))
      .toBe('AI model: provider/model');

    await act(async () => {
      bridge.receive({
        type: 'aiOperationChanged',
        payload: {
          requestId,
          streamId: 'stream-1',
          verb: 'develop',
          origin: 'editor',
          state: 'generating',
          message: 'is drafting',
        },
      });
    });
    expect(document.querySelector('[aria-label="Stop document AI"]')?.getAttribute('title'))
      .toBe('AI is drafting');
    await click('Stop document AI');
  });
});
