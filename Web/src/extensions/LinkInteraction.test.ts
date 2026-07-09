import { ensureSyntaxTree } from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { describe, expect, it } from 'vitest';
import {
  buildLinkChipDecorations,
  buildLinkEditChange,
  isAllowedExternalURL,
  linkInfoAt,
} from './LinkInteraction';
import { markdownConcealExtension, setShowRawFormattingEffect } from './MarkdownConceal';

function viewFor(doc: string): EditorView {
  const state = EditorState.create({ doc, extensions: [markdown(), markdownConcealExtension] });
  ensureSyntaxTree(state, state.doc.length, 1000);
  return {
    state,
    visibleRanges: [{ from: 0, to: state.doc.length }],
    viewport: { from: 0, to: state.doc.length },
  } as unknown as EditorView;
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
});

describe('link chips', () => {
  const noop = () => {};

  function chipRanges(doc: string): Array<[number, number]> {
    const decorations = buildLinkChipDecorations(viewFor(doc), noop);
    const ranges: Array<[number, number]> = [];
    decorations.between(0, doc.length, (from, to) => {
      ranges.push([from, to]);
    });
    return ranges;
  }

  it('replaces each http(s) link with one atomic chip covering the whole link', () => {
    const doc = 'See [Safari](https://apple.com) and [Docs](http://example.org).';
    const first: [number, number] = [doc.indexOf('[Safari'), doc.indexOf('apple.com)') + 'apple.com)'.length];
    const second: [number, number] = [doc.indexOf('[Docs'), doc.indexOf('example.org)') + 'example.org)'.length];
    expect(chipRanges(doc)).toEqual([first, second]);
  });

  it('leaves ticker-pdf links and non-links alone', () => {
    const doc = 'A [Book p.3](ticker-pdf://abc?page=3) citation and plain text.';
    expect(chipRanges(doc)).toEqual([]);
  });

  it('skips malformed links without URLs', () => {
    const doc = 'Broken [label]() here';
    expect(chipRanges(doc)).toEqual([]);
  });

  it('renders no chips while show-formatting is on', () => {
    const doc = 'See [Safari](https://apple.com).';
    const view = viewFor(doc);
    const raw = view.state.update({ effects: setShowRawFormattingEffect.of(true) }).state;
    const rawView = { ...view, state: raw } as unknown as EditorView;
    const decorations = buildLinkChipDecorations(rawView, noop);
    let count = 0;
    decorations.between(0, doc.length, () => {
      count += 1;
    });
    expect(count).toBe(0);
  });
});
