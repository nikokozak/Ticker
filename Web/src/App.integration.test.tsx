// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge, type SwiftToWebBridgeMessage, type WebToSwiftBridgeMessage } from './types/bridge';
import type { Stream, StreamAppendInboxJSON, StreamSummary } from './types/models';
import { parseMarkdown } from './richtext/markdown';
import { useToastStore } from './store/toastStore';
import { App } from './App';

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
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 0 });
  document.body.innerHTML = '';
});

describe('App stream loading', () => {
  it('shows typographic list metadata and a hairline only after scrolling', async () => {
    await boot();

    const first = document.querySelector('.stream-item') as HTMLButtonElement;
    expect(first.querySelector('.stream-meta')?.textContent).toMatch(/ago$/);
    expect(first.textContent).not.toContain('word');
    expect(first.textContent).not.toContain('source');
    expect(first.textContent).not.toContain('open question');

    Object.defineProperty(window, 'scrollY', { configurable: true, value: 1 });
    await act(async () => { window.dispatchEvent(new Event('scroll')); });
    expect(document.querySelector('.stream-list-header')?.classList.contains('stream-list-header--scrolled')).toBe(true);
  });

  it('renders plain-text previews and labels an empty stream', async () => {
    await boot();
    await act(async () => {
      bridge.receive({
        type: 'streamsLoaded',
        payload: {
          streams: [
            { ...summaries[0], previewLine: '<u>Components</u> with **bold** [docs](https://example.com)' },
            { ...summaries[1], previewLine: '' },
          ],
        },
      });
    });

    const previews = [...document.querySelectorAll('.stream-preview')].map((node) => node.textContent);
    expect(previews).toEqual(['Components with bold docs', 'Empty']);
  });

  it('clears list hover state on leave and before navigation', async () => {
    await boot();
    const first = document.querySelector('.stream-item') as HTMLButtonElement;
    await act(async () => {
      first.dispatchEvent(new MouseEvent('pointermove', { bubbles: true }));
    });
    expect(first.classList.contains('stream-item--hovered')).toBe(true);

    await act(async () => {
      document.querySelector('.stream-list-content')!.dispatchEvent(new MouseEvent('pointerout', {
        bubbles: true,
        relatedTarget: document.body,
      }));
    });
    expect(first.classList.contains('stream-item--hovered')).toBe(false);

    await act(async () => { first.click(); });
    expect(first.classList.contains('stream-item--hovered')).toBe(false);
  });

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

});
