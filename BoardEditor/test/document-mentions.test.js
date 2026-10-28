import { test, expect } from 'bun:test';
import { getSchema } from '@tiptap/core';
import { EditorState, TextSelection } from '@tiptap/pm/state';
import { history, undo, redo } from '@tiptap/pm/history';
import { createFlightDeckTiptapExtensions } from '../web/sol/docs/editor/prosemirror-flightdeck-schema.js';
import { mentionRange, insertMention } from '../web/document-mentions.js';
import { prosemirrorToFlightDeckContentModel } from '../web/sol/docs/editor/prosemirror-to-flightdeck.js';
import { markdownToProseMirrorDoc } from '../web/sol/docs/editor/markdown-to-prosemirror.js';
const schema = getSchema(createFlightDeckTiptapExtensions({ editable: true }));
function editor(text = 'See @plan') {
  const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text(text, [schema.marks.bold.create()])])]);
  const e = { schema, state: EditorState.create({ schema, doc, selection: TextSelection.atEnd(doc), plugins: [history()] }) };
  e.view = { dispatch(tr) { e.state = e.state.apply(tr); }, focus() {} }; return e;
}
test('canvas/doc/task links survive serialization and reopening, retain bold and undo/redo', () => {
  for (const row of [{ type: 'doc', id: 'd', label: 'Plan' }, { type: 'task', id: 't', label: 'Plan' }, { url: '/canvas.html?workspaceid=w&canvasid=c', id: 'c', label: 'Plan' }]) {
    const e = editor();
    expect(insertMention(e, row, mentionRange(e.state))).toBe(true);
    const json = e.state.doc.toJSON();
    expect(json.content[0].content[1].marks.some(m => m.type === 'bold')).toBe(true);
    const model = prosemirrorToFlightDeckContentModel(json);
    const reopened = markdownToProseMirrorDoc(model.content);
    const link = reopened.content[0].content.find(n => n.marks?.some(m => ['link', 'fdMention'].includes(m.type)));
    expect(link.text).toBe('Plan');
    expect(link.marks.find(m => m.type === (row.url ? 'link' : 'fdMention')).attrs[row.url ? 'href' : 'mentionId']).toBe(row.url || row.id);
    undo(e.state, e.view.dispatch); expect(e.state.doc.textContent).toBe('See @plan');
    redo(e.state, e.view.dispatch); expect(e.state.doc.textContent).toBe('See Plan ');
  }
});
test('stale ranges never replace different text; code and email do not offer suggestions', () => {
  const e = editor(); const range = mentionRange(e.state);
  e.view.dispatch(e.state.tr.insertText('x'));
  expect(insertMention(e, { type: 'doc', id: 'd', label: 'Plan' }, range)).toBe(false);
  expect(mentionRange(editor('email@example.test').state)).toBeNull();
  const c = editor('@code'); c.view.dispatch(c.state.tr.addMark(1, 6, schema.marks.code.create()));
  expect(mentionRange(c.state)).toBeNull();
});

test('record links activate on click/tap but preserve drag and Shift selection', async () => {
  const { recordLinkClickAllowed } = await import('../web/document-mentions.js');
  const event = { button: 0, detail: 1, clientX: 12, clientY: 12 };
  expect(recordLinkClickAllowed({ x: 10, y: 10 }, event)).toBe(true);
  expect(recordLinkClickAllowed({ x: 10, y: 10, cancelled: true }, event)).toBe(false);
  expect(recordLinkClickAllowed({ x: 10, y: 10 }, { ...event, clientX: 30 })).toBe(false);
  expect(recordLinkClickAllowed({ x: 10, y: 10 }, { ...event, shiftKey: true })).toBe(false);
  expect(recordLinkClickAllowed(null, { ...event, detail: 0 })).toBe(true);
});
