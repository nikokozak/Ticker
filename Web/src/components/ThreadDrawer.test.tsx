// @vitest-environment jsdom
import { act, createRef, type ComponentProps } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge } from '../types/bridge';
import type { AIExchangeJSON, StreamThreadAnchorJSON, StreamThreadJSON } from '../types/models';
import { useToastStore } from '../store/toastStore';
import {
  buildSidenoteDocumentJSON,
  ThreadDrawer,
  type ThreadDrawerHandle,
} from './ThreadDrawer';

const streamAnchor = (overrides: Partial<StreamThreadAnchorJSON> = {}): StreamThreadAnchorJSON => ({
  anchorId: 'anchor-1',
  threadId: 'thread-1',
  kind: 'stream_quote',
  quote: 'The MCU may draw too much power.',
  anchorSpanId: 'span-1',
  createdAt: new Date(0).toISOString(),
  ...overrides,
});

const thread = (overrides: Partial<StreamThreadJSON> = {}): StreamThreadJSON => {
  const value: StreamThreadJSON = {
    threadId: 'thread-1',
    streamId: 'stream-1',
    title: 'Check sleep current.',
    workingText: 'Check sleep current.',
    anchorText: 'The MCU may draw too much power.',
    anchors: [streamAnchor()],
    revision: 2,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    ...overrides,
  };
  return {
    ...value,
    docJSON: overrides.docJSON ?? buildSidenoteDocumentJSON(value.anchors ?? [], value.workingText),
    docFormatVersion: overrides.docFormatVersion ?? 1,
  };
};

let root: Root;
const drawerRef = createRef<ThreadDrawerHandle>();

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  const empty = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const none = () => Object.assign([] as unknown[], { item: () => null });
  for (const proto of [Range.prototype, Element.prototype, Text.prototype] as Array<{ getClientRects?: unknown; getBoundingClientRect?: unknown }>) {
    proto.getClientRects ??= none;
    proto.getBoundingClientRect ??= empty;
  }
  HTMLDialogElement.prototype.showModal ??= function showModal() { this.setAttribute('open', ''); };
  HTMLDialogElement.prototype.close ??= function close() { this.removeAttribute('open'); };
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

async function openListedSidenote() {
  await vi.waitFor(() => expect(document.querySelector('.sidenote-list-item')).not.toBeNull());
  await act(async () => {
    (document.querySelector('.sidenote-list-item') as HTMLButtonElement).click();
    await Promise.resolve();
  });
  await vi.waitFor(() => expect(document.querySelector('.sidenote-editor .ProseMirror')).not.toBeNull());
}

function typePrompt(value: string) {
  const prompt = document.querySelector('[aria-label="Ask AI in this Sidenote"]') as HTMLTextAreaElement;
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(prompt, value);
  prompt.dispatchEvent(new Event('input', { bubbles: true }));
}

function mockBridge(stored: StreamThreadJSON, save = vi.fn(), failAnchorRemoval = false) {
  return vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type, payload) => {
    if (type === 'listStreamThreads') return { threads: [stored] };
    if (type === 'loadStreamThread') return { thread: stored };
    if (type === 'saveStreamThread') {
      save(payload);
      return {
        conflict: false,
        thread: thread({
          ...stored,
          title: String(payload?.title ?? stored.title),
          workingText: String(payload?.workingText ?? stored.workingText),
          docJSON: String(payload?.docJSON ?? stored.docJSON),
          revision: Number(payload?.baseRevision ?? stored.revision) + 1,
        }),
      };
    }
    if (type === 'setThreadExchangeDisposition') return { saved: true };
    if (type === 'removeStreamThreadAnchor') {
      if (failAnchorRemoval) throw new Error('remove failed');
      return { removed: true };
    }
    if (type === 'deleteStreamThread') return { highlightIds: ['highlight-1'] };
    throw new Error(`Unexpected ${type}`);
  }) as typeof bridge.sendAsync);
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

describe('Sidenotes', () => {
  it('lists compact Sidenotes and opens one rich document with its evidence inline', async () => {
    const stored = thread();
    mockBridge(stored);

    await renderDrawer();
    const item = await vi.waitFor(() => document.querySelector('.sidenote-list-item') as HTMLButtonElement);
    expect(item.textContent).toContain('Check sleep current.');
    expect(item.textContent).toMatch(/years ago/);

    await openListedSidenote();
    expect(document.querySelector('.richtext-evidence')?.textContent)
      .toContain('The MCU may draw too much power.');
    expect(document.querySelector('.sidenote-editor .ProseMirror')?.textContent)
      .toContain('Check sleep current.');
    expect(document.querySelector('.sidenote-status-row')).toBeNull();
  });

  it('adds another live quote to the same document and saves the canonical draft', async () => {
    const stored = thread();
    const save = vi.fn();
    mockBridge(stored, save);
    await renderDrawer();
    await act(async () => { await drawerRef.current!.showThread(stored); });

    const pdfAnchor = streamAnchor({
      anchorId: 'anchor-2',
      kind: 'pdf_quote',
      quote: 'The regulator needs 300 mV of headroom.',
      anchorSpanId: undefined,
      sourceId: 'source-1',
      sourceShortTitle: 'Regulator data sheet',
      highlightId: 'highlight-1',
      sourcePage: 4,
    });
    await act(async () => {
      await expect(drawerRef.current!.addAnchor(pdfAnchor)).resolves.toBe(true);
    });

    expect(document.querySelectorAll('.richtext-evidence')).toHaveLength(2);
    expect(save).toHaveBeenCalledWith(expect.objectContaining({
      docFormatVersion: 1,
      docJSON: expect.stringContaining('anchor-2'),
    }));
  });

  it('opens an evidence quote in its original PDF location', async () => {
    const pdfAnchor = streamAnchor({
      kind: 'pdf_quote',
      sourceId: 'source-1',
      sourceShortTitle: 'Board spec',
      highlightId: 'highlight-1',
      sourcePage: 7,
    });
    const stored = thread({ anchors: [pdfAnchor] });
    const openPDF = vi.fn();
    mockBridge(stored);
    await renderDrawer({ onOpenPDFDestination: openPDF });
    await openListedSidenote();

    await act(async () => {
      (document.querySelector('.richtext-evidence') as HTMLElement).click();
    });
    expect(openPDF).toHaveBeenCalledWith('ticker-pdf://source-1?highlight=highlight-1&page=7');
  });

  it('keeps a quote in place when its anchor cannot be removed', async () => {
    const second = streamAnchor({ anchorId: 'anchor-2', quote: 'A second constraint.' });
    const stored = thread({
      anchors: [streamAnchor(), second],
      docJSON: buildSidenoteDocumentJSON([streamAnchor(), second], 'Working conclusion.'),
    });
    mockBridge(stored, vi.fn(), true);
    await renderDrawer();
    await openListedSidenote();

    const before = [...document.querySelectorAll('.richtext-evidence')].map((node) => node.textContent);
    await act(async () => {
      (document.querySelector('.richtext-evidence-remove') as HTMLButtonElement).click();
      await Promise.resolve();
    });

    await vi.waitFor(() => {
      const { toasts } = useToastStore.getState();
      expect(toasts[toasts.length - 1]?.message).toBe('The quote could not be removed.');
    });
    expect([...document.querySelectorAll('.richtext-evidence')].map((node) => node.textContent)).toEqual(before);
  });

  it('keeps an AI proposal outside the document until the user accepts it', async () => {
    const stored = thread();
    mockBridge(stored);
    const sent: Array<{ type: string; payload?: Record<string, unknown> }> = [];
    vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
    const endAI = vi.fn();
    await renderDrawer({ onBeginAI: () => true, onEndAI: endAI });
    await openListedSidenote();

    await act(async () => { typePrompt('Which part should we choose?'); });
    await act(async () => {
      (document.querySelector('.sidenote-prompt button') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    const request = sent.find((message) => message.type === 'thinkDocument');
    const requestId = String(request?.payload?.requestId);
    const receipt = {
      version: 1,
      kind: 'threadAI',
      requestId,
      anchor: { kind: 'stream', text: stored.anchorText },
      note: { sent: true, text: stored.workingText },
      turns: { includedRequestIds: [], totalAtSend: 0 },
      sourceContextMode: 'none',
      sources: [],
    };
    const exchange: AIExchangeJSON = {
      requestId,
      streamId: 'stream-1',
      threadId: 'thread-1',
      verb: 'thread',
      userInput: 'Which part should we choose?',
      responseRaw: 'Choose the part with lower sleep current.',
      sourceManifest: JSON.stringify(receipt),
      threadDisposition: 'pending',
      createdAt: new Date().toISOString(),
    };

    await act(async () => {
      bridge.receive({ type: 'threadAIContext', payload: { requestId, sentContext: receipt } });
      bridge.receive({ type: 'documentAIChunk', payload: { requestId, chunk: exchange.responseRaw } });
      bridge.receive({ type: 'documentAIComplete', payload: { requestId, exchange, sentContext: receipt } });
    });

    expect(document.querySelector('.sidenote-proposal')?.textContent).toContain(exchange.responseRaw);
    expect(document.querySelector('.sidenote-editor .ProseMirror')?.textContent).not.toContain(exchange.responseRaw);
    await act(async () => {
      ([...document.querySelectorAll<HTMLButtonElement>('.sidenote-proposal-actions button')]
        .find((button) => button.textContent === 'Keep in Sidenote')!).click();
      await Promise.resolve();
    });
    await vi.waitFor(() => expect(document.querySelector('.sidenote-proposal')).toBeNull());
    expect(document.querySelector('.sidenote-editor .ProseMirror')?.textContent).toContain(exchange.responseRaw);
    expect((bridge.sendAsync as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith(
      'setThreadExchangeDisposition',
      expect.objectContaining({ requestId, disposition: 'kept' }),
    );
    expect(sent.some((message) => message.type === 'saveStreamDocument')).toBe(false);
    expect(endAI).toHaveBeenCalledTimes(1);
  });

  it('promotes the current writing below its primary Stream quote', async () => {
    const stored = thread();
    mockBridge(stored);
    const promote = vi.fn().mockResolvedValue(true);
    await renderDrawer({ onPromote: promote });
    await act(async () => { await drawerRef.current!.showThread(stored); });
    await vi.waitFor(() => expect(document.querySelector('.sidenote-promote-main')).not.toBeNull());

    await act(async () => {
      (document.querySelector('.sidenote-promote-main') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    expect(promote).toHaveBeenCalledWith({
      text: 'Check sleep current.',
      threadId: 'thread-1',
      target: { kind: 'afterAnchor', anchorSpanId: 'span-1' },
    });
  });

  it('deletes the Sidenote while leaving already-promoted Stream text alone', async () => {
    const stored = thread();
    mockBridge(stored);
    const sent: Array<{ type: string; payload?: Record<string, unknown> }> = [];
    vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
    await renderDrawer();
    await openListedSidenote();

    await act(async () => {
      ([...document.querySelectorAll<HTMLButtonElement>('button')]
        .find((button) => button.textContent === 'Delete Sidenote')!).click();
    });
    await act(async () => {
      ([...document.querySelectorAll<HTMLButtonElement>('.modal-actions button')]
        .find((button) => button.textContent === 'Delete Sidenote')!).click();
      await Promise.resolve();
    });

    await vi.waitFor(() => expect(bridge.sendAsync).toHaveBeenCalledWith(
      'deleteStreamThread',
      { streamId: 'stream-1', threadId: 'thread-1' },
    ));
    expect(sent).toContainEqual({
      type: 'deletePdfHighlight',
      payload: { streamId: 'stream-1', highlightId: 'highlight-1' },
    });
  });

  it('removes a one-quote draft when the user leaves without writing', async () => {
    const stored = thread({
      title: 'The MCU may draw too much power.',
      workingText: '',
      docJSON: buildSidenoteDocumentJSON([streamAnchor()]),
    });
    const deleted = vi.fn();
    mockBridge(stored);
    await renderDrawer({ onSidenoteDeleted: deleted });
    await act(async () => { await drawerRef.current!.showThread(stored); });

    await act(async () => {
      await expect(drawerRef.current!.leave()).resolves.toBe(true);
    });

    expect(bridge.sendAsync).toHaveBeenCalledWith(
      'deleteStreamThread',
      { streamId: 'stream-1', threadId: 'thread-1' },
    );
    expect(deleted).toHaveBeenCalledWith('thread-1');
  });
});
