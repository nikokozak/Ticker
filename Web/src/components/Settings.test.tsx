// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridge } from '../types/bridge';
import { Settings } from './Settings';

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

let root: Root;

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  vi.spyOn(bridge, 'send').mockImplementation(() => {});
  vi.spyOn(bridge, 'sendAsync').mockImplementation((async (type: string) => {
    if (type === 'loadProxyAuth' || type === 'refreshProxyAuth') {
      return {
        state: 'active', supportId: 'support', deviceId: 'device',
        limits: { reqsPerMin: 10, tokensPerDay: 100, tokensPerMonth: 1000 },
        usage: { reqsThisMinute: 1, tokensToday: 2, tokensThisMonth: 3, dayResetAt: null, monthResetAt: null },
      };
    }
    return {};
  }) as typeof bridge.sendAsync);
  root = createRoot(document.querySelector('#root')!);
});

afterEach(async () => {
  await act(async () => root.unmount());
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

describe('Settings polish', () => {
  it('keeps feedback collapsed until requested and renders the font preview as a heading', async () => {
    await act(async () => {
      root.render(<Settings onClose={() => {}} />);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.querySelector('.settings-feedback-form')).toBe(null);
    const reportBug = [...document.querySelectorAll('button')]
      .find((button) => button.textContent === 'Report Bug') as HTMLButtonElement;
    await act(async () => reportBug.click());
    expect(reportBug.getAttribute('aria-expanded')).toBe('true');
    expect(document.querySelector('.settings-feedback-form')).not.toBe(null);
    expect(document.querySelector('.settings-editor-preview h3')?.textContent)
      .toBe('Markdown headings should read naturally.');
    expect(document.querySelector('.settings-editor-preview')?.textContent).not.toContain('##');
  });

  it('adds the settings header hairline only after content scrolls', async () => {
    await act(async () => {
      root.render(<Settings onClose={() => {}} />);
      await Promise.resolve();
    });
    const content = document.querySelector('.settings-content') as HTMLElement;
    Object.defineProperty(content, 'scrollTop', { configurable: true, value: 1 });
    await act(async () => content.dispatchEvent(new Event('scroll', { bubbles: true })));
    expect(document.querySelector('.settings-header')?.classList.contains('settings-header--scrolled')).toBe(true);
  });
});
