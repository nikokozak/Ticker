import { describe, expect, it } from 'vitest';
import { computeSelectionMenuPlacement, type SelectionMenuRect } from './selectionMenuPlacement';

const shellRect: SelectionMenuRect = {
  left: 0,
  right: 300,
  top: 0,
  bottom: 500,
};

const menuSize = {
  width: 100,
  height: 40,
};

describe('computeSelectionMenuPlacement', () => {
  it('places the menu above the selection when there is room', () => {
    expect(computeSelectionMenuPlacement({
      coords: { left: 130, right: 170, top: 100, bottom: 120 },
      shellRect,
      menuSize,
      viewportHeight: 600,
    })).toEqual({
      left: 150,
      top: 50,
    });
  });

  it('flips below the selection near the top of the viewport', () => {
    expect(computeSelectionMenuPlacement({
      coords: { left: 130, right: 170, top: 20, bottom: 38 },
      shellRect,
      menuSize,
      viewportHeight: 600,
    })).toEqual({
      left: 150,
      top: 48,
    });
  });

  it('clamps horizontally against the left and right shell edges', () => {
    expect(computeSelectionMenuPlacement({
      coords: { left: 0, right: 10, top: 100, bottom: 120 },
      shellRect,
      menuSize,
      viewportHeight: 600,
    }).left).toBe(58);

    expect(computeSelectionMenuPlacement({
      coords: { left: 290, right: 300, top: 100, bottom: 120 },
      shellRect,
      menuSize,
      viewportHeight: 600,
    }).left).toBe(242);
  });

  it('uses the visible shell center when the menu is wider than available space', () => {
    expect(computeSelectionMenuPlacement({
      coords: { left: 40, right: 60, top: 100, bottom: 120 },
      shellRect: { left: 0, right: 70, top: 0, bottom: 500 },
      menuSize,
      viewportHeight: 600,
    }).left).toBe(35);
  });
});
