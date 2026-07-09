import { ensureSyntaxTree } from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { describe, expect, it } from 'vitest';
import {
  buildLinkEditChange,
  isAllowedExternalURL,
  linkInfoAt,
  pointerMovementAllowsNavigation,
  positionTouchesLinkRange,
  xWithinLinkExtent,
} from './LinkInteraction';

function viewFor(doc: string): EditorView {
  const state = EditorState.create({ doc, extensions: [markdown()] });
  ensureSyntaxTree(state, state.doc.length, 1000);
  return { state } as EditorView;
}

describe('link interaction helpers', () => {
  it('builds a markdown link replacement change', () => {
    expect(buildLinkEditChange({ from: 4, to: 28 }, 'Example', 'https://example.com')).toEqual({
      from: 4,
      to: 28,
      insert: '[Example](https://example.com)',
    });
  });

  it('escapes edited link labels and trims URL fields', () => {
    expect(buildLinkEditChange({ from: 0, to: 10 }, 'A ] B', ' https://example.com/path ')).toEqual({
      from: 0,
      to: 10,
      insert: '[A \\] B](https://example.com/path)',
    });
  });

  it('rejects empty edited links', () => {
    expect(buildLinkEditChange({ from: 0, to: 10 }, '', 'https://example.com')).toBeNull();
    expect(buildLinkEditChange({ from: 0, to: 10 }, 'Example', '')).toBeNull();
  });

  it('allows only http and https external URLs', () => {
    expect(isAllowedExternalURL('https://example.com/path')).toBe(true);
    expect(isAllowedExternalURL('http://example.com')).toBe(true);
    expect(isAllowedExternalURL('ticker-pdf://source?page=1')).toBe(false);
    expect(isAllowedExternalURL('file:///etc/passwd')).toBe(false);
    expect(isAllowedExternalURL('javascript:alert(1)')).toBe(false);
    expect(isAllowedExternalURL('https:example.com')).toBe(false);
  });

  it('requires less than five pixels of pointer movement for navigation', () => {
    expect(pointerMovementAllowsNavigation({ x: 10, y: 10 }, { x: 13, y: 13 })).toBe(true);
    expect(pointerMovementAllowsNavigation({ x: 10, y: 10 }, { x: 13, y: 14 })).toBe(false);
    expect(pointerMovementAllowsNavigation(null, { x: 10, y: 10 })).toBe(false);
  });

  it('treats both link boundaries symmetrically', () => {
    expect(positionTouchesLinkRange(4, { from: 5, to: 20 })).toBe(false);
    expect(positionTouchesLinkRange(5, { from: 5, to: 20 })).toBe(true);
    expect(positionTouchesLinkRange(20, { from: 5, to: 20 })).toBe(true);
    expect(positionTouchesLinkRange(21, { from: 5, to: 20 })).toBe(false);
  });

  it('resolves markdown links at either boundary', () => {
    const doc = 'Go [Example](https://example.com) now';
    const from = doc.indexOf('[');
    const to = doc.indexOf(')', from) + 1;
    const view = viewFor(doc);

    expect(linkInfoAt(view, from)?.from).toBe(from);
    expect(linkInfoAt(view, to)?.to).toBe(to);
    expect(linkInfoAt(view, from - 1)).toBeNull();
    expect(linkInfoAt(view, to + 1)).toBeNull();
  });

  it('accepts click x-coordinates only inside the rendered link extent', () => {
    expect(xWithinLinkExtent(20, 10, 30)).toBe(true);
    expect(xWithinLinkExtent(6, 10, 30)).toBe(true);
    expect(xWithinLinkExtent(5, 10, 30)).toBe(false);
    expect(xWithinLinkExtent(35, 10, 30)).toBe(false);
  });
});
