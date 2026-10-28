// Wiki link handling in the document editor page (web/document-wiki.js), in the editor's own schema.
// Run: `bun test` in BoardEditor/.
import { test, expect } from 'bun:test';
import { getSchema } from '@tiptap/core';
import { Node as PMNode } from '@tiptap/pm/model';
import { EditorState, TextSelection } from '@tiptap/pm/state';
import { createFlightDeckTiptapExtensions } from '../web/sol/docs/editor/prosemirror-flightdeck-schema.js';
import { collectWikiRefs, occurrenceOf, bindWikiTitle, insertWikiLink } from '../web/document-wiki.js';

const schema = getSchema(createFlightDeckTiptapExtensions({ editable: true }));
const text = (value, marks) => ({ type: 'text', text: value, ...(marks ? { marks: marks.map((type) => ({ type })) } : {}) });
const wiki = (documentId, title) => ({ type: 'fdWikiLink', attrs: { documentId, title } });
const doc = (...blocks) => PMNode.fromJSON(schema, { type: 'doc', content: blocks });
const para = (...content) => ({ type: 'paragraph', content });

/// The few editor members the helpers use, over a bare ProseMirror state.
function fakeEditor(pmDoc) {
  const editor = {
    schema,
    state: EditorState.create({ schema, doc: pmDoc }),
    view: { dispatch(tr) { editor.state = editor.state.apply(tr); }, focus() {} },
  };
  return editor;
}

test('finds nodes and literal text in order, and never inside code', () => {
  const d = doc(
    para(text('a [[Dashboard]] b '), wiki(null, 'Plan'), text(' c '), text('[[InCode]]', ['code']), wiki('id-1', 'Bound'), text(' [[Dashboard]]', ['bold'])),
    { type: 'codeBlock', content: [text('[[Fenced]]')] },
  );
  const refs = collectWikiRefs(d);
  expect(refs.map((ref) => [ref.kind, ref.title, ref.documentId])).toEqual([
    ['literal', 'Dashboard', null], ['node', 'Plan', null], ['node', 'Bound', 'id-1'], ['literal', 'Dashboard', null],
  ]);
});

test('occurrence counts only same-title references that are not bound yet', () => {
  const d = doc(para(text('[[A]] '), wiki(null, 'A'), text(' '), wiki('x', 'A'), text(' [[B]] [[a]]')));
  const refs = collectWikiRefs(d);
  const as = refs.filter((ref) => ref.title.toLowerCase() === 'a' && !ref.documentId);
  expect(as.map((ref) => occurrenceOf(refs, ref))).toEqual([0, 1, 2]);
});

test('binding one occurrence changes only that reference and turns literal text into a bound link', () => {
  const editor = fakeEditor(doc(para(text('[[A]] and [[A]] and '), wiki(null, 'A'))));
  expect(bindWikiTitle(editor, { title: 'A', documentId: 'new', occurrence: 1 })).toBe(1);
  const refs = collectWikiRefs(editor.state.doc);
  expect(refs.map((ref) => [ref.kind, ref.documentId])).toEqual([['literal', null], ['node', 'new'], ['node', null]]);
  expect(editor.state.doc.textContent.startsWith('[[A]] and ')).toBe(true);
});

test('binding without an occurrence binds every match; nothing matching changes nothing', () => {
  const editor = fakeEditor(doc(para(text('[[A]] '), wiki(null, 'A'), text(' `x` '), text('[[A]]', ['code']))));
  expect(bindWikiTitle(editor, { title: ' a ', documentId: 'new' })).toBe(2);
  expect(collectWikiRefs(editor.state.doc).filter((ref) => ref.documentId === 'new').length).toBe(2);
  const before = editor.state.doc;
  expect(bindWikiTitle(editor, { title: 'Nope', documentId: 'z' })).toBe(0);
  expect(editor.state.doc).toBe(before);
});

test('insert replaces the typed query range with a link and falls back to the selection for a stale range', () => {
  const editor = fakeEditor(doc(para(text('See [[Das'))));
  const start = editor.state.doc.textContent.indexOf('[[') + 1;
  expect(insertWikiLink(editor, { documentId: 'd1', title: 'Dashboard', from: start, to: start + 5 })).toEqual({ occurrence: -1, count: 0 });
  expect(editor.state.doc.toJSON().content[0].content.map((node) => node.text ?? node.attrs.title).join('')).toBe('See Dashboard');
  expect(collectWikiRefs(editor.state.doc)[0]).toMatchObject({ kind: 'node', documentId: 'd1', title: 'Dashboard' });
  expect(insertWikiLink(editor, { documentId: null, title: 'New page', from: 9999, to: 10000 })).toEqual({ occurrence: 0, count: 1 });
  expect(collectWikiRefs(editor.state.doc).some((ref) => ref.documentId === null && ref.title === 'New page')).toBe(true);
});

test('a title-only link inserted by the picker is saved as a title-only node, not as text', () => {
  const editor = fakeEditor(doc(para(text('x'))));
  editor.state = editor.state.apply(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 2)));
  insertWikiLink(editor, { title: 'Draft page' });
  expect(editor.state.doc.toJSON().content[0].content.some((node) => node.type === 'fdWikiLink' && !node.attrs.documentId)).toBe(true);
});

test('a changed reference count means nothing is bound by position', () => {
  const editor = fakeEditor(doc(para(text('[[A]] and [[A]]'))));
  const before = editor.state.doc;
  expect(bindWikiTitle(editor, { title: 'A', documentId: 'new', occurrence: 1, expectedCount: 3 })).toBe(-1);
  expect(editor.state.doc).toBe(before);
  expect(bindWikiTitle(editor, { title: 'A', documentId: 'new', occurrence: 1, expectedCount: 2 })).toBe(1);
});
