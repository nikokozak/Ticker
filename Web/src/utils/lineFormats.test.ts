import { EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { continueBulletListOnEnter, toggleLineFormat, type LineFormat } from './lineFormats';

function apply(doc: string, anchor: number, head: number, format: LineFormat): string | null {
  const state = EditorState.create({ doc, selection: { anchor, head } });
  const changes = toggleLineFormat(state, state.selection.main, format);
  if (!changes) return null;
  return state.update({ changes }).state.doc.toString();
}

describe('toggleLineFormat', () => {
  it('adds a heading marker to a plain line (caret, no selection)', () => {
    expect(apply('Title\nbody', 2, 2, 'h2')).toBe('## Title\nbody');
  });

  it('removes the marker when the line already has the target format', () => {
    expect(apply('## Title', 4, 4, 'h2')).toBe('Title');
  });

  it('switches between formats instead of stacking markers', () => {
    expect(apply('# Title', 3, 3, 'h3')).toBe('### Title');
    expect(apply('> quoted', 3, 3, 'h1')).toBe('# quoted');
    expect(apply('- item', 3, 3, 'quote')).toBe('> item');
  });

  it('formats every non-blank line in a multi-line selection', () => {
    const doc = 'one\n\ntwo';
    expect(apply(doc, 0, doc.length, 'quote')).toBe('> one\n\n> two');
  });

  it('unformats only when ALL lines already match; otherwise completes the set', () => {
    const mixed = '- one\ntwo';
    expect(apply(mixed, 0, mixed.length, 'bullet')).toBe('- one\n- two');
    const uniform = '- one\n- two';
    expect(apply(uniform, 0, uniform.length, 'bullet')).toBe('one\ntwo');
  });

  it('treats *, +, and - as the same bullet format', () => {
    const doc = '* one\n+ two';
    expect(apply(doc, 0, doc.length, 'bullet')).toBe('one\ntwo');
  });

  it('preserves leading indentation', () => {
    expect(apply('  nested item', 5, 5, 'bullet')).toBe('  - nested item');
  });

  it('returns null for blank-only selections', () => {
    expect(apply('\n\n', 0, 2, 'h1')).toBeNull();
  });
});

describe('continueBulletListOnEnter', () => {
  function pressEnter(doc: string, caret: number): { handled: boolean; doc: string; caret: number } {
    const state = EditorState.create({ doc, selection: { anchor: caret } });
    let next = state;
    const handled = continueBulletListOnEnter({ state, dispatch: (tr) => { next = tr.state; } });
    return { handled, doc: next.doc.toString(), caret: next.selection.main.head };
  }

  it('continues tight even when the underlying list is loose', () => {
    const doc = '- Apples\n\n- Pears\n\nplain';
    const caret = doc.indexOf('Pears') + 'Pears'.length;
    expect(pressEnter(doc, caret)).toEqual({
      handled: true,
      doc: '- Apples\n\n- Pears\n- \n\nplain',
      caret: doc.indexOf('Pears') + 'Pears'.length + '\n- '.length,
    });
  });

  it('splits mid-item text into the next bullet', () => {
    const result = pressEnter('- one two', '- one'.length);
    expect(result).toEqual({ handled: true, doc: '- one\n-  two', caret: '- one\n- '.length });
  });

  it('exits the list on an empty item', () => {
    expect(pressEnter('- Pears\n- ', '- Pears\n- '.length)).toEqual({
      handled: true,
      doc: '- Pears\n',
      caret: '- Pears\n'.length,
    });
  });

  it('falls through on non-bullet lines and inside the marker', () => {
    expect(pressEnter('plain text', 5).handled).toBe(false);
    expect(pressEnter('- item', 1).handled).toBe(false);
  });
});
