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
  document.elementFromPoint ??= () => null;
  HTMLDialogElement.prototype.showModal ??= function showModal() {
    this.setAttribute('open', '');
  };
  HTMLDialogElement.prototype.close ??= function close() {
    this.removeAttribute('open');
  };
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

async function selectEditorText(text: string) {
  const node = [...editor().querySelectorAll('*')]
    .flatMap((element) => [...element.childNodes])
    .find((candidate) => candidate.nodeType === Node.TEXT_NODE && candidate.textContent?.includes(text));
  expect(node, `Expected ${JSON.stringify(text)} in the editor`).toBeDefined();
  const range = document.createRange();
  const start = node!.textContent!.indexOf(text);
  range.setStart(node!, start);
  range.setEnd(node!, start + text.length);
  editor().focus();
  window.getSelection()!.removeAllRanges();
  window.getSelection()!.addRange(range);
  await act(async () => {
    document.dispatchEvent(new Event('selectionchange'));
    await Promise.resolve();
  });
}

async function enterPrompt(value: string) {
  const input = document.querySelector('.ai-prompt-input') as HTMLTextAreaElement;
  expect(input, 'Expected AI prompt input').toBeDefined();
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
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

function imageFile(): File {
  return new File(['pixels'], 'shot.png', { type: 'image/png' });
}

function clipboardEvent(file: File, text?: string, html?: string): ClipboardEvent {
  const event = new Event('paste', { bubbles: true, cancelable: true }) as ClipboardEvent;
  const image = { kind: 'file', type: file.type, getAsFile: () => file };
  const items = [
    ...(text === undefined ? [] : [{ kind: 'string', type: 'text/plain', getAsFile: () => null }]),
    ...(html === undefined ? [] : [{ kind: 'string', type: 'text/html', getAsFile: () => null }]),
    image,
  ];
  const types = [
    ...(text === undefined ? [] : ['text/plain']),
    ...(html === undefined ? [] : ['text/html']),
    'Files',
  ];
  Object.defineProperty(event, 'clipboardData', {
    value: {
      files: [file],
      items,
      types,
      getData: (type: string) => (
        type === 'text/plain' ? text ?? '' : type === 'text/html' ? html ?? '' : ''
      ),
    },
  });
  return event;
}

function dropEvent(file: File): DragEvent {
  const event = new Event('drop', { bubbles: true, cancelable: true }) as DragEvent;
  Object.defineProperty(event, 'dataTransfer', {
    value: {
      files: [file],
      items: [{ kind: 'file', type: file.type, getAsFile: () => file }],
      types: ['Files'],
      getData: () => '',
    },
  });
  return event;
}

async function imageSaveMessage(): Promise<WebToSwiftBridgeMessage> {
  await vi.waitFor(() => {
    expect(sent.some((message) => message.type === 'saveImage')).toBe(true);
  });
  return [...sent].reverse().find((message) => message.type === 'saveImage')!;
}

async function finishImageSave(message: WebToSwiftBridgeMessage, assetUrl = 'ticker-asset://stream-1/shot.png') {
  await act(async () => {
    bridge.receive({
      type: 'imageSaved',
      payload: {
        requestId: message.payload?.requestId,
        assetUrl,
        relativePath: 'stream-1/shot.png',
      },
    });
    await Promise.resolve();
  });
}

async function renderStream(next: Stream, options: {
  pendingMatchText?: string | null;
  onClearPendingMatch?: () => void;
} = {}) {
  await act(async () => {
    root!.render(
      <RichStreamEditor
        key={next.id}
        stream={next}
        onBack={() => {}}
        onDelete={() => {}}
        {...options}
      />,
    );
    await Promise.resolve();
  });
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
  await renderStream(stream);
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

describe('an image save that lands after the editor is gone', () => {
  it('does not write into an editor that has been torn down', async () => {
    // Paste, then leave before the host answers. The save is already in flight and
    // will still resolve; by then this editor is destroyed and belongs to a stream
    // the user is no longer looking at. Dispatching into it throws out of a bridge
    // message, and the image lands nowhere the user can see.
    await act(async () => { editor().dispatchEvent(clipboardEvent(imageFile())); });
    const request = await imageSaveMessage();

    await act(async () => {
      root?.unmount();
      await Promise.resolve();
    });
    root = null;

    await finishImageSave(request);

    // Measured: the insert lands in the destroyed editor, no save is ever issued
    // for it, and nothing is said. The user pasted an image and it vanished — and
    // the asset is on disk with nothing pointing at it.
    const saves = vi.mocked(bridge.sendAsync).mock.calls
      .filter(([type]) => type === 'saveStreamDocument');
    expect(saves).toHaveLength(0);
    expect(useToastStore.getState().toasts.map((toast) => toast.message).join(' '))
      .toMatch(/image/i);
  });
});

describe('RichStreamEditor document AI', () => {
  it('sends a prompt as the query and the selected text as context', async () => {
    await selectEditorText('Original');
    await click('Send and prompt AI');
    await enterPrompt('Make it concrete.');
    await click('Send prompt to AI');

    const requestId = activeRequestId();
    expect(lastSent()).toMatchObject({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: 'stream-1',
        query: 'Make it concrete.',
        context: 'Original',
        verb: 'ask',
        imageURLs: [],
      },
    });

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'A reply.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });
    expect([...editor().querySelectorAll('p')].map((node) => node.textContent))
      .toEqual(['Original paragraph.', 'A reply.']);

    await act(async () => {
      editor().dispatchEvent(new KeyboardEvent('keydown', {
        key: 'z', ctrlKey: true, bubbles: true, cancelable: true,
      }));
    });
    expect(editor().textContent).toBe('Original paragraph.');
  });

  it('does not send a blank prompt', async () => {
    await click('Send and prompt AI');
    await enterPrompt(' \n ');
    const input = document.querySelector('.ai-prompt-input') as HTMLTextAreaElement;
    await act(async () => {
      input.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', ctrlKey: true, bubbles: true, cancelable: true,
      }));
      await Promise.resolve();
    });

    expect(sent.filter((message) => message.type === 'thinkDocument')).toHaveLength(0);
    expect(document.querySelector('.ai-prompt-input')).not.toBe(null);
  });

  it('does not open a prompt without text to attach', async () => {
    await renderStream({
      ...stream,
      id: 'empty-stream',
      document: { ...stream.document, streamId: 'empty-stream', markdown: '' },
    });
    await click('Send and prompt AI');

    expect(document.querySelector('.ai-prompt-input')).toBe(null);
    expect(useToastStore.getState().toasts.map((toast) => toast.message))
      .toEqual(['Select text or place the cursor in a paragraph to use as context.']);
  });

  it.each([
    ['Ask with AI', 'ask'],
    ['Define with AI', 'define'],
  ] as const)('supports %s without replacing the passage', async (label, verb) => {
    await click(label);
    const requestId = activeRequestId();
    expect(lastSent()).toMatchObject({
      type: 'thinkDocument',
      payload: {
        query: 'Original paragraph.',
        context: undefined,
        verb,
      },
    });

    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'A reply.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });
    expect([...editor().querySelectorAll('p')].map((node) => node.textContent))
      .toEqual(['Original paragraph.', 'A reply.']);
  });

  it('can append a reply after the whole document is selected', async () => {
    editor().focus();
    await act(async () => {
      editor().dispatchEvent(new KeyboardEvent('keydown', {
        key: 'a', ctrlKey: true, bubbles: true, cancelable: true,
      }));
    });
    await click('Ask with AI');

    expect(lastSent()).toMatchObject({
      type: 'thinkDocument',
      payload: { query: 'Original paragraph.', verb: 'ask' },
    });
    await click('Stop document AI');
  });

  it.each(['cancel', 'error'] as const)('restores an appended reply on %s', async (exit) => {
    await click('Ask with AI');
    const requestId = activeRequestId();
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Partial.' } });
    });

    if (exit === 'cancel') {
      await click('Stop document AI');
    } else {
      await act(async () => {
        bridge.receive({
          type: 'documentAIError',
          payload: { requestId, error: 'Provider broke.', errorCode: 'upstream_error' },
        });
      });
    }

    expect([...editor().querySelectorAll('p')].map((node) => node.textContent))
      .toEqual(['Original paragraph.']);
    expect(editor().getAttribute('contenteditable')).toBe('true');
  });

  it('rewrites from a prompt and does not expose challenge', async () => {
    expect(document.querySelector('[aria-label="Challenge with AI"]')).toBe(null);
    await click('Rewrite with AI');
    await enterPrompt('Make it shorter.');
    await click('Send prompt to AI');

    const requestId = activeRequestId();
    expect(lastSent()).toMatchObject({
      type: 'thinkDocument',
      payload: {
        query: 'Make it shorter.',
        context: 'Original paragraph.',
        verb: 'rewrite',
      },
    });
    await act(async () => {
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: 'Shorter.' } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId } });
    });
    expect(editor().textContent).toBe('Shorter.');
  });

  it('keeps a reply streamed in several chunks to one undo step', async () => {
    await click('Send to AI');
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
    await click('Send to AI');
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
    await click('Send to AI');
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
      await click('Send to AI');
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
      await click('Send to AI');
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
    await click('Send to AI');
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
    await click('Send to AI');
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
    await click('Send to AI');
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

    await click('Send to AI');
    const messages = sent.filter((candidate) => candidate.type === 'thinkDocument');
    const message = messages[messages.length - 1];
    expect(message?.payload?.query).toBe('Original');
    await click('Stop document AI');
  });

  it('cancels the host request and restores the original text', async () => {
    await click('Send to AI');
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
    await click('Send to AI');
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
    await click('Send to AI');
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
      await click('Send to AI');
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

    await click('Send to AI');
    await act(async () => {
      (document.querySelector('.back-button') as HTMLButtonElement).click();
      release(true);
      await draining;
      await Promise.resolve();
    });

    expect(sent.filter((message) => message.type === 'thinkDocument')).toHaveLength(0);
  });

  it('reflects model and operation updates for only the active request', async () => {
    await click('Send to AI');
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

describe('RichStreamEditor images', () => {
  it('saves a browser-copied image even when its clipboard also carries HTML', async () => {
    const event = clipboardEvent(
      imageFile(),
      undefined,
      '<img src="https://example.test/remote.png">',
    );
    editor().dispatchEvent(event);
    const save = await imageSaveMessage();

    expect(event.defaultPrevented).toBe(true);
    await finishImageSave(save);
    expect(editor().querySelector('img')?.getAttribute('src'))
      .toBe('ticker-asset://stream-1/shot.png');
  });

  it('treats whitespace-only plain text as an image paste', async () => {
    const event = clipboardEvent(
      imageFile(),
      ' \n ',
      '<img src="https://example.test/remote.png">',
    );
    editor().dispatchEvent(event);
    const save = await imageSaveMessage();
    await finishImageSave(save);

    expect(editor().querySelector('img')?.getAttribute('src'))
      .toBe('ticker-asset://stream-1/shot.png');
  });

  it('pastes a saved image as one undo step using the bridge wire shape', async () => {
    const event = clipboardEvent(imageFile());
    editor().dispatchEvent(event);
    const save = await imageSaveMessage();

    expect(event.defaultPrevented).toBe(true);
    expect(save).toEqual({
      type: 'saveImage',
      payload: {
        streamId: 'stream-1',
        data: 'cGl4ZWxz',
        requestId: expect.any(String),
      },
    });

    await act(async () => {
      bridge.receive({
        type: 'imageSaved',
        payload: {
          requestId: 'a different upload',
          assetUrl: 'ticker-asset://stream-1/wrong.png',
          relativePath: 'stream-1/wrong.png',
        },
      });
      await Promise.resolve();
    });
    expect(editor().querySelector('img')).toBe(null);

    await finishImageSave(save);
    expect(editor().querySelector('img')?.getAttribute('src'))
      .toBe('ticker-asset://stream-1/shot.png');

    await act(async () => {
      editor().dispatchEvent(new KeyboardEvent('keydown', {
        key: 'z', ctrlKey: true, bubbles: true, cancelable: true,
      }));
    });
    expect(editor().querySelector('img')).toBe(null);
    expect(editor().textContent).toBe('Original paragraph.');
  });

  it('drops an image file through the same save-before-insert path', async () => {
    const event = dropEvent(imageFile());
    editor().dispatchEvent(event);
    const save = await imageSaveMessage();
    expect(event.defaultPrevented).toBe(true);

    await finishImageSave(save);
    expect(editor().querySelector('img')?.getAttribute('alt')).toBe('shot');
  });

  it('leaves a mixed text-and-image paste to the text clipboard path', async () => {
    const event = clipboardEvent(
      imageFile(),
      'copied words',
      '<p>copied words<img src="https://example.test/remote.png"></p>',
    );
    await act(async () => {
      editor().dispatchEvent(event);
      await Promise.resolve();
    });

    expect(sent.filter((message) => message.type === 'saveImage')).toHaveLength(0);
    expect(editor().textContent).toContain('copied words');
    expect(editor().querySelector('img')).toBe(null);
  });

  it('reports a failed image save and inserts nothing', async () => {
    editor().dispatchEvent(clipboardEvent(imageFile()));
    const save = await imageSaveMessage();

    await act(async () => {
      bridge.receive({
        type: 'imageSaveError',
        payload: { requestId: save.payload?.requestId, error: 'Disk is full.' },
      });
      await Promise.resolve();
    });

    expect(editor().querySelector('img')).toBe(null);
    expect(useToastStore.getState().toasts.map((toast) => toast.message))
      .toEqual(['Disk is full.']);
  });

  it('ignores an upload error after its editor has closed', async () => {
    editor().dispatchEvent(clipboardEvent(imageFile()));
    const failed = await imageSaveMessage();
    await renderStream({
      ...stream,
      id: 'stream-2',
      document: { ...stream.document, streamId: 'stream-2' },
    });
    useToastStore.getState().clearToasts();
    await act(async () => {
      bridge.receive({
        type: 'imageSaveError',
        payload: { requestId: failed.payload?.requestId, error: 'Too late.' },
      });
      await Promise.resolve();
    });
    expect(useToastStore.getState().toasts).toEqual([]);
  });

  it('stores a resize in the node attr, hides its markdown token, and undoes only the resize', async () => {
    editor().dispatchEvent(clipboardEvent(imageFile()));
    const save = await imageSaveMessage();
    await finishImageSave(save);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 550));
    });

    const image = editor().querySelector('img')!;
    image.getBoundingClientRect = () => ({
      top: 0, bottom: 100, left: 0, right: 200, width: 200, height: 100,
      x: 0, y: 0, toJSON: () => ({}),
    });
    const handle = document.querySelector('[aria-label="Resize image"]')!;
    await act(async () => {
      handle.dispatchEvent(new MouseEvent('mousedown', {
        clientX: 100, bubbles: true, cancelable: true,
      }));
      window.dispatchEvent(new MouseEvent('mouseup'));
    });
    expect(image.hasAttribute('width')).toBe(false);

    await act(async () => {
      handle.dispatchEvent(new MouseEvent('mousedown', {
        clientX: 100, bubbles: true, cancelable: true,
      }));
      window.dispatchEvent(new MouseEvent('mousemove', { clientX: 220 }));
      window.dispatchEvent(new MouseEvent('mouseup'));
      await new Promise((resolve) => setTimeout(resolve, 400));
    });

    expect(editor().textContent).not.toContain('{width=');
    const saves = vi.mocked(bridge.sendAsync).mock.calls
      .filter(([type]) => type === 'saveStreamDocument');
    expect(saves[saves.length - 1]?.[1]?.markdown)
      .toBe('![shot](ticker-asset://stream-1/shot.png){width=320}Original paragraph.');

    await act(async () => {
      editor().dispatchEvent(new KeyboardEvent('keydown', {
        key: 'z', ctrlKey: true, bubbles: true, cancelable: true,
      }));
    });
    expect(editor().querySelector('img')).not.toBe(null);
    expect(editor().querySelector('img')?.hasAttribute('width')).toBe(false);

    await click('Send to AI');
    await act(async () => {
      handle.dispatchEvent(new MouseEvent('mousedown', {
        clientX: 100, bubbles: true, cancelable: true,
      }));
      window.dispatchEvent(new MouseEvent('mousemove', { clientX: 220 }));
      window.dispatchEvent(new MouseEvent('mouseup'));
    });
    expect(editor().querySelector('img')?.hasAttribute('width')).toBe(false);
    await click('Stop document AI');
  });
});

describe('RichStreamEditor scroll position', () => {
  const withScroll = (id: string, scrollOffset: number): Stream => ({
    ...stream,
    id,
    document: {
      ...stream.document,
      streamId: id,
      scrollOffset,
    },
  });

  it('restores once and never reasserts the old offset over later editor scrolling', async () => {
    vi.useFakeTimers();
    try {
      const opened = withScroll('scroll-stream', 84);
      await renderStream(opened);
      const scroller = document.querySelector('.stream-content') as HTMLElement;
      expect(scroller.scrollTop).toBe(84);

      scroller.scrollTop = 20;
      await act(async () => {
        bridge.receive({
          type: 'streamDocumentAppended',
          payload: { streamId: opened.id, fragment: 'Appended.', revision: 2, spans: [] },
        });
        await vi.advanceTimersByTimeAsync(300);
      });
      expect(scroller.scrollTop).toBe(20);

      await renderStream({ ...opened, document: { ...opened.document, scrollOffset: 12 } });
      expect(scroller.scrollTop).toBe(20);

      sent = [];
      await renderStream(withScroll('next-stream', 0));
      expect(sent.filter((message) => message.type === 'saveScrollPosition')).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('debounces scroll saves and sends the latest offset', async () => {
    vi.useFakeTimers();
    try {
      await renderStream(withScroll('scroll-stream', 0));
      sent = [];
      const scroller = document.querySelector('.stream-content') as HTMLElement;

      scroller.scrollTop = 40;
      scroller.dispatchEvent(new Event('scroll'));
      await vi.advanceTimersByTimeAsync(600);
      scroller.scrollTop = 75;
      scroller.dispatchEvent(new Event('scroll'));
      await vi.advanceTimersByTimeAsync(400);
      expect(sent.filter((message) => message.type === 'saveScrollPosition')).toHaveLength(0);

      await vi.advanceTimersByTimeAsync(600);
      expect(sent.filter((message) => message.type === 'saveScrollPosition')).toEqual([{
        type: 'saveScrollPosition',
        payload: { streamId: 'scroll-stream', offset: 75 },
      }]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('flushes a pending scroll save when leaving the stream', async () => {
    vi.useFakeTimers();
    try {
      await renderStream(withScroll('scroll-stream', 0));
      sent = [];
      const scroller = document.querySelector('.stream-content') as HTMLElement;
      scroller.scrollTop = 63;
      scroller.dispatchEvent(new Event('scroll'));

      await renderStream(withScroll('next-stream', 0));
      expect(sent.filter((message) => message.type === 'saveScrollPosition')).toContainEqual({
        type: 'saveScrollPosition',
        payload: { streamId: 'scroll-stream', offset: 63 },
      });
    } finally {
      vi.useRealTimers();
    }
  });
});

describe('RichStreamEditor search arrival', () => {
  const matchingStream: Stream = {
    ...stream,
    id: 'match-stream',
    document: {
      ...stream.document,
      streamId: 'match-stream',
      markdown: 'First paragraph.\n\nA needle in the second paragraph.',
    },
  };

  it('selects and scrolls to a pending match exactly once', async () => {
    const clear = vi.fn();
    const options = { pendingMatchText: 'needle', onClearPendingMatch: clear };
    await renderStream(matchingStream, options);

    expect(window.getSelection()?.toString()).toBe('needle');
    expect(clear).toHaveBeenCalledTimes(1);

    await renderStream({ ...matchingStream, title: 'Same stream' }, options);
    expect(clear).toHaveBeenCalledTimes(1);
  });

  it('clears a missed match without moving the cursor', async () => {
    const clear = vi.fn();
    await renderStream(matchingStream, {
      pendingMatchText: 'absent',
      onClearPendingMatch: clear,
    });

    expect(editor().textContent).toContain('needle');
    expect(window.getSelection()?.toString()).toBe('');
    expect(clear).toHaveBeenCalledTimes(1);
  });

  it('does nothing when no match is pending', async () => {
    const clear = vi.fn();
    await renderStream(matchingStream, {
      pendingMatchText: null,
      onClearPendingMatch: clear,
    });
    expect(clear).not.toHaveBeenCalled();
  });
});
