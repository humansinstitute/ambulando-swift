import { test, expect } from 'bun:test';
import { commentPosition } from '../web/document-comment-overlay.js';
const rect = (left, top, width, height = 22) => ({ left, top, width, height, right: left + width, bottom: top + height });
const viewport = { left: 0, top: 0, width: 390, height: 400 };
test('selection icon uses last visible line at right and clamps without changing text geometry', () => {
  const lines = [rect(12, 40, 220), rect(12, 62, 100)];
  expect(commentPosition(lines, viewport)).toEqual({ x: 342, y: 51 });
  expect(commentPosition([rect(12, 62, 360)], viewport)).toEqual({ x: 342, y: 51 });
  expect(commentPosition(lines, viewport)).toEqual({ x: 342, y: 51 });
});
test('keyboard-visible viewport, scroll and resize bound the action and hide offscreen selections', () => {
  expect(commentPosition([rect(10, 390, 200)], viewport)).toEqual({ x: 342, y: 352 });
  expect(commentPosition([rect(10, -100, 200)], viewport)).toBeNull();
  expect(commentPosition([rect(10, 420, 200)], viewport)).toBeNull();
  expect(commentPosition([rect(10, 62, 200)], { ...viewport, width: 180 })).toEqual({ x: 132, y: 51 });
  expect(commentPosition([rect(10, 162, 200)], { ...viewport, top: 150, height: 200 })).toEqual({ x: 342, y: 154 });
  expect(commentPosition([], viewport)).toBeNull();
  expect(commentPosition([rect(10, NaN, 30)], viewport)).toBeNull();
  expect(commentPosition([rect(10, 40, 30)], { ...viewport, height: NaN })).toBeNull();
  expect(commentPosition([rect(10, 40, 0)], viewport)).toBeNull();
});
