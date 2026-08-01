// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge, type SwiftToWebBridgeMessage, type WebToSwiftBridgeMessage } from './types/bridge';
import type { Stream, StreamAppendInboxJSON, StreamSummary } from './types/models';
import { parseMarkdown } from './richtext/markdown';
import { useToastStore } from './store/toastStore';
import { App } from './App';
import { buildSidenoteDocumentJSON } from './components/ThreadDrawer';

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  const empty = () => ({
    top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0,
    toJSON: () => ({}),
  });
  const none = () => Object.assign([] as unknown[], { item: () => null });
  for (const proto of [Range.prototype, Element.prototype, Text.prototype] as Array<{
    getClientRects?: unknown;
    getBoundingClientRect?: unknown;
  }>) {
    proto.getClientRects ??= none;
    proto.getBoundingClientRect ??= empty;
  }
  document.elementFromPoint ??= () => null;
  Element.prototype.scrollIntoView ??= () => {};
});

const now = new Date(0).toISOString();
const summaries: StreamSummary[] = ['stream-1', 'stream-2'].map((id, index) => ({
  id,
  title: `Stream ${index + 1}`,
  sourceCount: 0,
  charCount: 4,
  wordCount: 1,
  imageCount: 0,
  openQuestionCount: 0,
  updatedAt: now,
  previewLine: 'Base',
}));
const inbox: StreamAppendInboxJSON[] = [{
  seq: 1,
  appendId: 'append-1',
  fragment: 'I’ve been wondering about Cape Verde',
  rawSpansJSON: '[]',
  createdAt: now,
}];

function loaded(
  requestId: number,
  appendInbox: StreamAppendInboxJSON[] = [],
  streamId = 'stream-1',
): SwiftToWebBridgeMessage {
  const stream: Stream = {
    id: streamId,
    title: streamId === 'stream-1' ? 'Stream 1' : 'Stream 2',
    sourceScope: 'auto',
    sources: [],
    document: {
      streamId,
      docJSON: JSON.stringify(parseMarkdown('Base').toJSON()),
      docFormatVersion: 1,
      markdown: appendInbox.length ? `Base\n\n${inbox[0].fragment}` : 'Base',
      revision: 1,
      scrollOffset: 0,
      createdAt: now,
      updatedAt: now,
    },
    spans: [],
    pendingAppends: [],
    appendInbox,
    marginNotes: [],
    createdAt: now,
    updatedAt: now,
  };
  return {
    type: 'streamLoaded',
    payload: {
      requestId,
      stream,
      sourceScope: 'auto',
      scrollOffset: 0,
      spans: [],
      pendingAppends: [],
      appendInbox,
      marginNotes: [],
    },
  };
}

function inboxChanged(): SwiftToWebBridgeMessage {
  return {
    type: 'streamAppendInboxChanged',
    payload: {
      streamId: 'stream-1',
      appendInbox: inbox,
      isNewStream: false,
      source: 'quickPanel',
    },
  };
}

let root: Root;
let sent: WebToSwiftBridgeMessage[];

async function boot() {
  await act(async () => {
    root.render(<App />);
    await Promise.resolve();
  });
  await act(async () => {
    bridge.receive({ type: 'storageStateChanged', payload: { state: 'ready' } });
    bridge.receive({ type: 'streamsLoaded', payload: { streams: summaries } });
    await Promise.resolve();
  });
}

async function selectStream(title = 'Stream 1') {
  const button = [...document.querySelectorAll<HTMLButtonElement>('.stream-item')]
    .find((candidate) => candidate.textContent?.includes(title));
  expect(button, `Expected ${title}`).toBeDefined();
  await act(async () => {
    button!.click();
    await Promise.resolve();
  });
}

function loads() {
  return sent.filter((message) => message.type === 'loadStream');
}

async function openSidenotes() {
  const button = await vi.waitFor(() => {
    const found = document.querySelector('[aria-label^="Sidenotes,"]') as HTMLButtonElement | null;
    expect(found).not.toBeNull();
    return found!;
  });
  await act(async () => {
    button.click();
    await Promise.resolve();
  });
}

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  useToastStore.getState().clearToasts();
  sent = [];
  vi.spyOn(bridge, 'send').mockImplementation((message) => { sent.push(message); });
  vi.spyOn(bridge, 'sendAsync').mockImplementation(
    (async (type: string) => type === 'loadProxyAuth'
      ? { state: 'active' }
      : { revision: 2 }) as typeof bridge.sendAsync,
  );
  root = createRoot(document.querySelector('#root')!);
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
    await Promise.resolve();
  });
  useToastStore.getState().clearToasts();
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

describe('App stream loading', () => {
  it('keeps the list recoverable while a stream load is pending', async () => {
    await boot();
    await selectStream();

    const buttons = [...document.querySelectorAll<HTMLButtonElement>('.stream-item')];
    expect(buttons.every((button) => !button.disabled)).toBe(true);

    await selectStream('Stream 2');
    expect(loads().map((message) => message.payload?.id)).toEqual(['stream-1', 'stream-2']);
  });

  it('refreshes a snapshot when an append lands during its load', async () => {
    await boot();
    await selectStream();
    const firstRequest = Number(loads()[0].payload?.requestId);

    await act(async () => {
      bridge.receive(inboxChanged());
      await Promise.resolve();
    });

    expect(loads()).toHaveLength(2);
    const secondRequest = Number(loads()[1].payload?.requestId);
    await act(async () => {
      bridge.receive(loaded(firstRequest));
      bridge.receive(loaded(secondRequest, inbox));
      await Promise.resolve();
    });

    expect(document.querySelector('.ProseMirror')?.textContent)
      .toContain('I’ve been wondering about Cape Verde');
  });

  it('does not disturb a pending load for another stream or malformed inbox', async () => {
    await boot();
    await selectStream();

    await act(async () => {
      bridge.receive({
        ...inboxChanged(),
        payload: { ...inboxChanged().payload, streamId: 'stream-2' },
      });
      bridge.receive({
        ...inboxChanged(),
        payload: { ...inboxChanged().payload, appendInbox: {} },
      });
      await Promise.resolve();
    });

    expect(loads()).toHaveLength(1);
    expect(loads()[0].payload?.id).toBe('stream-1');
  });

  it('opens a stream created by a capture', async () => {
    await boot();

    await act(async () => {
      bridge.receive({
        ...inboxChanged(),
        payload: { ...inboxChanged().payload, isNewStream: true },
      });
      await Promise.resolve();
    });

    expect(loads().map((message) => message.payload?.id)).toEqual(['stream-1']);
  });

  it('keeps an append delivered between load acceptance and editor mount', async () => {
    await boot();
    await selectStream();
    const requestId = Number(loads()[0].payload?.requestId);

    await act(async () => {
      bridge.receive(loaded(requestId));
      bridge.receive(inboxChanged());
      await Promise.resolve();
    });

    expect(document.querySelector('.ProseMirror')?.textContent)
      .toContain('I’ve been wondering about Cape Verde');
  });

  it('does not switch streams while a local Sidenote has a save conflict', async () => {
    const primaryAnchor = {
      anchorId: 'anchor-1',
      threadId: 'thread-1',
      kind: 'stream_quote' as const,
      quote: 'Base',
      anchorSpanId: 'span-1',
      createdAt: now,
    };
    const storedThread = {
      threadId: 'thread-1',
      streamId: 'stream-1',
      title: 'Power budget',
      workingText: 'Stored elsewhere',
      docJSON: buildSidenoteDocumentJSON([primaryAnchor], 'Stored elsewhere'),
      docFormatVersion: 1,
      anchorText: 'Base',
      anchors: [primaryAnchor],
      revision: 8,
      createdAt: now,
      updatedAt: now,
    };
    vi.mocked(bridge.sendAsync).mockImplementation((async (type: string, payload) => {
      if (type === 'loadProxyAuth') return { state: 'active' };
      if (type === 'listStreamThreads') return { threads: [storedThread] };
      if (type === 'loadStreamThread') return { thread: { ...storedThread, revision: 2 } };
      if (type === 'addStreamThreadAnchor') {
        const wire = (payload?.anchors as Array<Record<string, unknown>>)[0];
        return {
          anchor: {
            ...wire,
            threadId: 'thread-1',
            sourceShortTitle: 'Data sheet',
            sourcePage: Number(wire.page),
          },
        };
      }
      if (type === 'saveStreamThread') return { conflict: true, thread: storedThread };
      return { revision: 2 };
    }) as typeof bridge.sendAsync);
    await boot();
    await selectStream();
    const requestId = Number(loads()[0].payload?.requestId);
    await act(async () => {
      bridge.receive(loaded(requestId));
      await Promise.resolve();
    });

    await openSidenotes();
    await vi.waitFor(() => expect(document.querySelector('.sidenote-list-item')).not.toBeNull());
    await act(async () => {
      (document.querySelector('.sidenote-list-item') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    await act(async () => {
      bridge.receive({
        type: 'pdfThreadRequested',
        payload: {
          streamId: 'stream-1',
          sourceId: 'source-1',
          sourceName: 'data-sheet.pdf',
          shortTitle: 'Data sheet',
          highlightId: 'highlight-1',
          page: 4,
          quote: 'Unsaved local evidence',
          createdAt: now,
          rects: [{ page: 4, x: 0.1, y: 0.2, w: 0.3, h: 0.04 }],
        },
      });
      await Promise.resolve();
    });
    await vi.waitFor(() => expect(document.querySelector('.sidenote-warning')).not.toBeNull());
    await act(async () => {
      bridge.receive({
        type: 'streamDocumentAppended',
        payload: {
          streamId: 'stream-2',
          fragment: 'Capture',
          revision: 1,
          isNewStream: true,
          source: 'quickPanel',
          spans: [],
        },
      });
      await Promise.resolve();
    });

    expect(loads().map((message) => message.payload?.id)).toEqual(['stream-1']);
    expect(document.querySelector('.sidenote-editor')?.textContent).toContain('Unsaved local evidence');
    expect(document.querySelector('.ProseMirror')?.textContent).toBe('Base');
  });

  it('remounts the drawer with the next stream after a successful flush', async () => {
    const firstThread = {
      threadId: 'thread-1', streamId: 'stream-1', title: 'First thread', workingText: '',
      anchorText: 'First anchor', revision: 0, createdAt: now, updatedAt: now,
    };
    const secondThread = {
      ...firstThread,
      threadId: 'thread-2',
      streamId: 'stream-2',
      title: 'Second thread',
      anchorText: 'Second anchor',
    };
    vi.mocked(bridge.sendAsync).mockImplementation((async (type: string, payload) => {
      if (type === 'loadProxyAuth') return { state: 'active' };
      if (type === 'listStreamThreads') {
        return { threads: [payload?.streamId === 'stream-2' ? secondThread : firstThread] };
      }
      if (type === 'loadStreamThread') return { thread: firstThread };
      return { revision: 2 };
    }) as typeof bridge.sendAsync);
    await boot();
    await selectStream();
    await act(async () => {
      bridge.receive(loaded(Number(loads()[0].payload?.requestId)));
      await Promise.resolve();
    });
    await openSidenotes();
    await vi.waitFor(() => expect(document.querySelector('.sidenote-list-item')?.textContent)
      .toContain('First thread'));
    await act(async () => {
      (document.querySelector('.sidenote-list-item') as HTMLButtonElement).click();
      await Promise.resolve();
      bridge.receive({
        type: 'streamDocumentAppended',
        payload: {
          streamId: 'stream-2', fragment: 'Capture', revision: 1,
          isNewStream: true, source: 'quickPanel', spans: [],
        },
      });
      await Promise.resolve();
    });
    await vi.waitFor(() => expect(loads().some((message) => message.payload?.id === 'stream-2')).toBe(true));
    const nextLoad = loads().find((message) => message.payload?.id === 'stream-2')!;
    await act(async () => {
      bridge.receive(loaded(Number(nextLoad.payload?.requestId), [], 'stream-2'));
      await Promise.resolve();
    });

    expect(document.querySelector('.sidenote-panel')).toBeNull();
    await openSidenotes();
    await vi.waitFor(() => expect(document.querySelector('.sidenote-list-item')?.textContent)
      .toContain('Second thread'));
  });
});
