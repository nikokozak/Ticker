// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge } from '../types/bridge';
import { SourcesModal } from './SourcesModal';

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  HTMLDialogElement.prototype.showModal ??= function showModal() { this.setAttribute('open', ''); };
  HTMLDialogElement.prototype.close ??= function close() { this.removeAttribute('open'); };
});

let root: Root;

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  vi.spyOn(bridge, 'send').mockImplementation(() => {});
  root = createRoot(document.querySelector('#root')!);
});

afterEach(async () => {
  await act(async () => root.unmount());
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

describe('SourcesModal empty state', () => {
  it('shows one invitation and focuses the primary Add Source action', async () => {
    await act(async () => {
      root.render(
        <SourcesModal
          isOpen
          streamId="stream-1"
          sources={[]}
          onClose={() => {}}
          onSourceRemoved={() => {}}
          onSourceAIExclusionChanged={() => {}}
        />,
      );
      await Promise.resolve();
    });

    const empty = document.querySelector('.sources-modal-empty')!;
    const add = empty.querySelector('button') as HTMLButtonElement;
    expect(empty.textContent).toBe('No sources yet. Drag files here orAdd Source');
    expect(document.querySelector('.sources-modal-header p')).toBe(null);
    expect(document.querySelectorAll('button').length).toBe(2);
    expect(add.classList.contains('primary-button')).toBe(true);
    expect(document.activeElement).toBe(add);
  });
});
