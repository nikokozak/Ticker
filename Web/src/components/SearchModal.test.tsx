// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge } from '../types/bridge';
import { SearchModal } from './SearchModal';

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  HTMLDialogElement.prototype.showModal ??= function showModal() { this.setAttribute('open', ''); };
  HTMLDialogElement.prototype.close ??= function close() { this.removeAttribute('open'); };
});

let root: Root;

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  root = createRoot(document.querySelector('#root')!);
});

afterEach(async () => {
  vi.useRealTimers();
  await act(async () => { root.unmount(); });
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

describe('SearchModal', () => {
  it('renders query-specific feedback when search returns no results', async () => {
    vi.useFakeTimers();
    vi.spyOn(bridge, 'sendAsync').mockResolvedValue({
      currentStreamResults: [],
      otherStreamResults: [],
    });
    await act(async () => {
      root.render(
        <SearchModal
          isOpen
          currentStreamId={null}
          isStreamOpen={false}
          onClose={() => {}}
          onNavigateToMatch={() => {}}
          onNavigateToStream={() => {}}
          onNavigateToSource={() => {}}
        />,
      );
    });
    const input = document.querySelector('.search-modal-input') as HTMLInputElement;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(input, 'sensor');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(200);
      await Promise.resolve();
    });

    expect(bridge.sendAsync).toHaveBeenCalledWith('hybridSearch', { query: 'sensor', limit: 20 });
    expect(document.querySelector('.search-modal-empty')?.textContent)
      .toBe('No results for “sensor”');
  });

  it('renders result titles and snippets as plain text', async () => {
    vi.useFakeTimers();
    vi.spyOn(bridge, 'sendAsync').mockResolvedValue({
      currentStreamResults: [],
      otherStreamResults: [{
        id: 'result-1',
        streamId: 'stream-1',
        streamTitle: '<u>Sensor</u> **notes**',
        sourceType: 'document',
        title: '# <u>Components</u> [guide](https://example.com)',
        snippet: '<u>Reading</u> with **bold** [link](https://example.com)',
      }],
    });
    await act(async () => {
      root.render(
        <SearchModal
          isOpen
          currentStreamId={null}
          isStreamOpen={false}
          onClose={() => {}}
          onNavigateToMatch={() => {}}
          onNavigateToStream={() => {}}
          onNavigateToSource={() => {}}
        />,
      );
    });
    const input = document.querySelector('.search-modal-input') as HTMLInputElement;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(input, 'sensor');
      input.dispatchEvent(new Event('input', { bubbles: true }));
      await vi.advanceTimersByTimeAsync(200);
    });

    expect(document.querySelector('.search-result-title')?.textContent)
      .toBe('[Sensor notes]Components guide');
    expect(document.querySelector('.search-result-snippet')?.textContent)
      .toBe('Reading with bold link');
  });
});
