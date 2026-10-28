import { test, expect } from 'bun:test';
import { getSchema } from '@tiptap/core';
import { EditorState, TextSelection } from '@tiptap/pm/state';
import { history, undo, redo } from '@tiptap/pm/history';
import { createFlightDeckTiptapExtensions } from '../web/sol/docs/editor/prosemirror-flightdeck-schema.js';
import { splitBlock } from '@tiptap/pm/commands';
import { documentMentions, mentionRange, insertMention } from '../web/document-mentions.js';
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

function mentionPlugin(posts = []) {
  return documentMentions({ post: value => posts.push(value), changed() {} }).extension.config.addProseMirrorPlugins.call({})[0];
}
function keyEvent(target = null, extra = {}) {
  return { target, key: 'Enter', preventDefault() { this.defaultPrevented = true; }, ...extra };
}
function linkElement(mention = true) {
  return {
    dataset: mention ? { mentionType: 'doc', mentionId: 'petes-notes' } : {},
    getAttribute: () => mention ? '#' : 'https://example.test/notes',
    closest(selector) { return mention || selector.includes('a[href]') ? this : null; },
  };
}
test('ProseMirror synthetic Return and non-Element targets fall through all link handlers', () => {
  const posts = [], plugin = mentionPlugin(posts), view = editor().view;
  for (const target of [null, undefined, {}, { nodeType: 9 }, { nodeType: 3, parentElement: null }]) {
    const event = keyEvent(target);
    expect(plugin.props.handleKeyDown(view, event)).toBe(false);
    expect(plugin.props.handleDOMEvents.pointerdown(view, event)).toBe(false);
    expect(plugin.props.handleDOMEvents.click(view, event)).toBe(false);
    expect(event.defaultPrevented).toBeUndefined();
  }
  expect(posts).toEqual([]);
});
test('actual link handlers retain text-child taps, keyboard activation and selection gestures', () => {
  const posts = [], plugin = mentionPlugin(posts), view = editor().view;
  const events = plugin.props.handleDOMEvents;
  for (const link of [linkElement(), linkElement(false)]) {
    const target = { nodeType: 3, parentElement: link };
    const event = keyEvent(target, { key: undefined, button: 0, detail: 1, clientX: 10, clientY: 10 });
    events.pointerdown(view, event);
    expect(events.click(view, event)).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(posts.at(-1).id || posts.at(-1).url).toBe(link.dataset.mentionId || link.getAttribute('href'));
    const count = posts.length;
    events.pointerdown(view, event);
    events.pointermove(view, { clientX: 30, clientY: 10 });
    expect(events.click(view, event)).toBe(false);
    events.pointerdown(view, { ...event, shiftKey: true });
    expect(events.click(view, { ...event, shiftKey: true })).toBe(false);
    expect(posts.length).toBe(count);
  }
  expect(plugin.props.handleKeyDown(view, keyEvent(linkElement()))).toBe(true);
  const marked = editor('Petes Notes');
  const tr = marked.state.tr.addMark(1, marked.state.doc.content.size - 1, schema.marks.fdMention.create({ mentionType: 'doc', mentionId: 'petes-notes', label: 'Petes Notes' }));
  marked.view.dispatch(tr.setSelection(TextSelection.create(tr.doc, 3)));
  for (const modifier of ['ctrlKey', 'metaKey']) {
    expect(plugin.props.handleKeyDown({ state: marked.state }, keyEvent(null, { [modifier]: true }))).toBe(true);
    expect(posts.at(-1).id).toBe('petes-notes');
  }
  expect(plugin.props.handleKeyDown(view, keyEvent({ closest: () => null }))).toBe(false);
});
test('synthetic Return before first link splits normally, preserves caret and saved link identity', () => {
  for (const mark of [schema.marks.fdMention.create({ label: 'Petes Notes', mentionType: 'doc', mentionId: 'petes-notes' }), schema.marks.link.create({ href: 'https://example.test/notes' })]) {
    const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text('Petes Notes', [mark])])]);
    let state = EditorState.create({ schema, doc, selection: TextSelection.create(doc, 1) });
    const view = { get state() { return state; }, dispatch(tr) { state = state.apply(tr); } };
    view.dispatch(state.tr.insertText('Intro'));
    expect(state.selection.from).toBe(6);
    // prosemirror-view's keyEvent(13, 'Enter') is undispatched on iOS Return paths.
    expect(mentionPlugin().props.handleKeyDown(view, keyEvent())).toBe(false);
    expect(splitBlock(state, view.dispatch)).toBe(true);
    expect(state.selection.$from.parent.textContent).toBe('Petes Notes');
    expect(state.selection.$from.parentOffset).toBe(0);
    expect(state.doc.child(0).textContent).toBe('Intro');
    view.dispatch(state.tr.insertText('More '));
    expect(state.selection.$from.parentOffset).toBe(5);
    const saved = prosemirrorToFlightDeckContentModel(state.doc.toJSON());
    const restored = schema.nodeFromJSON(markdownToProseMirrorDoc(saved.content));
    expect(restored.child(0).textContent).toBe('Intro');
    expect(restored.child(1).textContent).toBe('More Petes Notes');
    expect(restored.child(1).lastChild.marks.some(m => m.type === mark.type && (m.attrs.mentionId || m.attrs.href) === (mark.attrs.mentionId || mark.attrs.href))).toBe(true);
    expect(restored.child(0).firstChild.marks.map(m => m.type.name)).toEqual(state.doc.child(0).firstChild.marks.map(m => m.type.name));
  }
});
