import { test, expect } from 'bun:test';
import { getSchema } from '@tiptap/core';
import { TextSelection } from '@tiptap/pm/state';
import { createFlightDeckTiptapExtensions } from '../web/sol/docs/editor/prosemirror-flightdeck-schema.js';
import { captureSelection, revealSelection } from '../web/document-selection.js';
import { markdownSource } from '../web/document-preserve.js';
const schema = getSchema(createFlightDeckTiptapExtensions({ editable: true }));
function editor(json, from, to) {
  const doc = schema.nodeFromJSON(json);
  return { state: { doc, selection: TextSelection.create(doc, from, to) },
    commands: { setTextSelection(range) { this.range = range; } } };
}
test('rich anchor captures UTF-16 positions and quote across formatted blocks, reopens and refuses ambiguous relocation', () => {
  const e = editor({ type: 'doc', content: [
    { type: 'paragraph', content: [{ type: 'text', text: 'A😀B', marks: [{ type: 'bold' }] }] },
    { type: 'paragraph', content: [{ type: 'text', text: 'Next' }] },
  ] }, 2, 10);
  const anchor = captureSelection(e);
  expect(anchor.anchor_quote).toBe('😀B\nNex');
  expect(anchor.anchor_start_offset).toBe(2);
  expect(revealSelection(e, anchor).state).toBe('found');
  expect(e.commands.range).toEqual({ from: 2, to: 10 });
  const ambiguous = editor({ type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'same same' }] }] }, 1, 5);
  expect(revealSelection(ambiguous, { anchor_quote: 'same', anchor_start_offset: 100, anchor_end_offset: 104 }).state).toBe('stale');
});
test('Markdown anchor uses original line coordinates and distinguishes duplicate quotes on separate lines', () => {
  const markdown = '# Title\n\nFirst **same**\n\nSecond **same**\n';
  const e = editor(markdownSource(markdown).doc, 26, 30);
  const spans = []; e.state.doc.descendants((node, pos) => { if (node.isText) spans.push([node.text, pos]); });
  const pair = spans.filter(([text]) => text === 'same').at(-1);
  e.state.selection = TextSelection.create(e.state.doc, pair[1], pair[1] + 4);
  const anchor = captureSelection(e, markdown);
  expect(anchor).toEqual({ anchor_quote: 'same', anchor_line_number: 5 });
  expect(revealSelection(e, anchor, markdown).state).toBe('found');
  expect(e.commands.range).toEqual({ from: pair[1], to: pair[1] + 4 });
});
