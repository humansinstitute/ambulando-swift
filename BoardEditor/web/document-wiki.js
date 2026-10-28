// Wiki links inside the native document editor page. Native-owned (not a sol copy): the app decides what a link opens, where a
// page is created and what a picker offers; this file only finds links in the document, reports clicks and `[[` typing, and
// applies the app's answer (insert a link, bind a created page). Stored content is never rewritten by merely opening a
// document: literal `[[Title]]` text stays text until the person links or creates it.
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import { Extension } from '@tiptap/core';
import { wikiPickerRange } from './sol/docs/editor/wiki-extension.js';

const LITERAL = /\[\[([^\]\n]+)\]\]/g;
/// Marks under which `[[Title]]` is still plain text. Code, links and mentions keep their literal brackets (matches the app's reader).
const PLAIN_MARKS = new Set(['bold', 'italic', 'strike', 'underline']);

export const normalizeTitle = (title) => String(title ?? '').trim().toLocaleLowerCase();

const plainText = (node) => (node.marks || []).every((mark) => PLAIN_MARKS.has(mark.type.name));

/// Every wiki reference in document order: bound or title-only link nodes, and literal `[[Title]]` text outside code.
export function collectWikiRefs(doc) {
  const refs = [];
  doc.descendants((node, pos, parent) => {
    if (parent?.type.name === 'codeBlock' || node.type.name === 'codeBlock') return false;
    if (node.type.name === 'fdWikiLink') {
      refs.push({ kind: 'node', from: pos, to: pos + node.nodeSize, title: node.attrs.title || '', documentId: node.attrs.documentId || null });
      return false;
    }
    if (node.isText && plainText(node)) {
      for (const match of node.text.matchAll(LITERAL)) {
        const title = match[1].trim();
        if (!title) continue;
        refs.push({ kind: 'literal', from: pos + match.index, to: pos + match.index + match[0].length, title, documentId: null });
      }
    }
    return true;
  });
  return refs;
}

/// Which matching title-only reference this is (document order), the index the app uses to bind exactly the opened link.
export function occurrenceOf(refs, ref) {
  const wanted = normalizeTitle(ref.title);
  let index = 0;
  for (const other of refs) {
    if (other.documentId || normalizeTitle(other.title) !== wanted) continue;
    if (other.from === ref.from) return index;
    index += 1;
  }
  return 0;
}

export function refAt(doc, pos) {
  return collectWikiRefs(doc).find((ref) => pos >= ref.from && pos <= ref.to) || null;
}

/// Replaces `[from, to)` (or the selection) with a link node. `documentId` null makes a title-only link, which the app then
/// resolves or creates.
export function insertWikiLink(editor, { documentId = null, title, from, to }) {
  const size = editor.state.doc.content.size;
  const range = Number.isInteger(from) && Number.isInteger(to) && from >= 0 && to <= size && from <= to
    ? { from, to } : { from: editor.state.selection.from, to: editor.state.selection.to };
  const node = editor.schema.nodes.fdWikiLink.create({ documentId: documentId || null, title: String(title || '').trim() || 'Untitled document' });
  const tr = editor.state.tr.replaceWith(range.from, range.to, node);
  editor.view.dispatch(tr.scrollIntoView());
  editor.view.focus();
  return true;
}

/// Gives the page's unresolved links titled `title` the created page's id (one occurrence, or all when `occurrence` is null).
/// Literal `[[Title]]` text outside code becomes a bound link node. Returns how many references were bound.
export function bindWikiTitle(editor, { title, documentId, occurrence = null }) {
  const wanted = normalizeTitle(title);
  let seen = 0;
  const wanting = [];
  for (const ref of collectWikiRefs(editor.state.doc)) {
    if (ref.documentId || normalizeTitle(ref.title) !== wanted) continue;
    const mine = seen;
    seen += 1;
    if (occurrence === null || occurrence === undefined || occurrence === mine) wanting.push(ref);
  }
  if (!wanting.length) return 0;
  const tr = editor.state.tr;
  for (const ref of wanting.reverse()) {
    tr.replaceWith(ref.from, ref.to, editor.schema.nodes.fdWikiLink.create({ documentId, title: ref.title }));
  }
  editor.view.dispatch(tr);
  return wanting.length;
}

/// The plugin: marks literal `[[Title]]` as links to activate, reports clicks, Cmd/Ctrl+Enter and `[[` typing to the app.
export function wikiExtension({ post, isEditing = () => true }) {
  const key = new PluginKey('ambulandoWiki');
  let lastQuery = '';
  const report = (view) => {
    const range = isEditing() ? wikiPickerRange(view.state) : null;
    const next = range ? JSON.stringify([range.from, range.to, range.query]) : '';
    if (next === lastQuery) return;
    lastQuery = next;
    post(range ? { type: 'wiki-query', active: true, query: range.query, from: range.from, to: range.to } : { type: 'wiki-query', active: false });
  };
  const activate = (view, ref) => {
    post({ type: 'wiki', action: 'activate', title: ref.title, documentId: ref.documentId, occurrence: occurrenceOf(collectWikiRefs(view.state.doc), ref), from: ref.from, to: ref.to });
  };
  return Extension.create({
    name: 'ambulandoWiki',
    addProseMirrorPlugins() {
      return [new Plugin({
        key,
        state: {
          init: (_config, state) => DecorationSet.create(state.doc, literalDecorations(state.doc)),
          apply: (tr, old, _old, state) => (tr.docChanged ? DecorationSet.create(state.doc, literalDecorations(state.doc)) : old),
        },
        props: {
          decorations(state) { return key.getState(state); },
          handleClick(view, pos, event) {
            if (event.button !== 0 || event.shiftKey) return false;
            const target = event.target;
            if (!(target instanceof Element) || !target.closest('.fd-wiki-literal')) return false;
            const ref = collectWikiRefs(view.state.doc).find((candidate) => candidate.kind === 'literal' && pos >= candidate.from && pos <= candidate.to);
            if (!ref) return false;
            activate(view, ref);
            return true;
          },
          handleKeyDown(view, event) {
            if (event.key !== 'Enter' || !(event.metaKey || event.ctrlKey)) return false;
            const ref = refAt(view.state.doc, view.state.selection.from);
            if (!ref) return false;
            event.preventDefault();
            activate(view, ref);
            return true;
          },
        },
        view: () => ({ update: report, destroy() { lastQuery = ''; post({ type: 'wiki-query', active: false }); } }),
      })];
    },
  });
}

function literalDecorations(doc) {
  return collectWikiRefs(doc).filter((ref) => ref.kind === 'literal').map((ref) => Decoration.inline(ref.from, ref.to, {
    class: 'fd-wiki-literal', role: 'link', 'data-wiki-title': ref.title, 'aria-label': `${ref.title}: page link`,
  }));
}
