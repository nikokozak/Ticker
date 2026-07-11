import { describe, expect, it } from 'vitest';
import { EditorSelection, EditorState } from '@codemirror/state';
import { toggleInlineMark, type InlineMarker } from './inlineMarks';

interface ToggleResult {
  doc: string;
  from: number;
  to: number;
  selected: string;
}

function maybeToggle(doc: string, from: number, to: number, marker: InlineMarker) {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.range(from, to),
  });
  return toggleInlineMark(state, state.selection.main, marker);
}

function toggle(doc: string, from: number, to: number, marker: InlineMarker): ToggleResult {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.range(from, to),
  });
  const edit = toggleInlineMark(state, state.selection.main, marker);
  expect(edit).not.toBeNull();
  const next = state.update({
    changes: edit!.changes,
    selection: edit!.newSelection,
  }).state;
  const selection = next.selection.main;
  return {
    doc: next.doc.toString(),
    from: selection.from,
    to: selection.to,
    selected: next.sliceDoc(selection.from, selection.to),
  };
}

describe('toggleInlineMark', () => {
  it('wraps the selected text', () => {
    expect(toggle('Hello world', 6, 11, '**')).toEqual({
      doc: 'Hello **world**',
      from: 8,
      to: 13,
      selected: 'world',
    });
  });

  it('unwraps a selection that exactly includes the markers', () => {
    expect(toggle('**world**', 0, 9, '**')).toEqual({
      doc: 'world',
      from: 0,
      to: 5,
      selected: 'world',
    });
  });

  it('unwraps markers just outside the selection', () => {
    expect(toggle('**world**', 2, 7, '**')).toEqual({
      doc: 'world',
      from: 0,
      to: 5,
      selected: 'world',
    });
  });

  it('wraps multi-word selections', () => {
    expect(toggle('one two three', 4, 13, '*')).toEqual({
      doc: 'one *two three*',
      from: 5,
      to: 14,
      selected: 'two three',
    });
  });

  it('wraps when only one side touches an existing bold marker', () => {
    expect(toggle('**world', 2, 7, '**')).toEqual({
      doc: '****world**',
      from: 4,
      to: 9,
      selected: 'world',
    });
  });

  it('wraps italic inside an existing bold selection', () => {
    expect(toggle('**world**', 2, 7, '*')).toEqual({
      doc: '***world***',
      from: 3,
      to: 8,
      selected: 'world',
    });
  });

  it('keeps leading and trailing whitespace outside new markers', () => {
    expect(toggle('  word  ', 0, 8, '**')).toEqual({
      doc: '  **word**  ',
      from: 4,
      to: 8,
      selected: 'word',
    });
  });

  it('does nothing for whitespace-only selections', () => {
    expect(maybeToggle('one   two', 3, 6, '**')).toBeNull();
  });

  it('wraps trimmed non-empty content on each selected line', () => {
    const input = ' one \n\n two  \nthree ';
    expect(toggle(input, 0, input.length, '**')).toEqual({
      doc: ' **one** \n\n **two**  \n**three** ',
      from: 1,
      to: 31,
      selected: '**one** \n\n **two**  \n**three**',
    });
  });

  it('toggles a whitespace-edged multi-line wrap back off', () => {
    const first = toggle(' one \n two ', 0, 11, '**');
    expect(first.doc).toBe(' **one** \n **two** ');

    const second = toggle(first.doc, first.from, first.to, '**');
    expect(second).toEqual({
      doc: ' one \n two ',
      from: 1,
      to: 10,
      selected: 'one \n two',
    });
  });

  const underline = { open: '<u>', close: '</u>' };

  it('wraps with asymmetric underline markers', () => {
    expect(toggle('Hello world', 6, 11, underline)).toEqual({
      doc: 'Hello <u>world</u>',
      from: 9,
      to: 14,
      selected: 'world',
    });
  });

  it('unwraps a selection that exactly includes underline markers', () => {
    expect(toggle('<u>world</u>', 0, 12, underline)).toEqual({
      doc: 'world',
      from: 0,
      to: 5,
      selected: 'world',
    });
  });

  it('unwraps underline markers just outside the selection', () => {
    expect(toggle('<u>world</u>', 3, 8, underline)).toEqual({
      doc: 'world',
      from: 0,
      to: 5,
      selected: 'world',
    });
  });

  it('round-trips a multi-line underline wrap', () => {
    const first = toggle('one\ntwo', 0, 7, underline);
    expect(first.doc).toBe('<u>one</u>\n<u>two</u>');

    const second = toggle(first.doc, first.from, first.to, underline);
    expect(second.doc).toBe('one\ntwo');
  });
});
