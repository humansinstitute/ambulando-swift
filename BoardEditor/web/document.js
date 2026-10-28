// Native host page for the web document editor (Tiptap with sol's schema and extensions, vendored in `sol/docs`).
//
// The app shows a document natively and swaps this page in, on the same page, while the user edits. The page has no
// signer, keys, `window.nostr`, network or storage: the app gives it the stored document, and takes back the edited
// document as JSON (rich documents) or Markdown (Markdown documents), which it saves through its own lease, draft and
// version checks. Untouched content goes back exactly as stored (document-preserve.js).
//
// In:  window.ambulandoDocument.load / command / insertUploads / replaceUpload / setImage / setStyle / snapshot / focus /
//      wikiInsert / wikiBind / wikiTitles / wikiSelection
// Out: webkit.messageHandlers.document.postMessage(JSON): ready, loaded, change, state, need-image, paste-files, error,
//      wiki (a link was opened), wiki-query (`[[` typing);
//      webkit.messageHandlers.documentFile.postMessage(`<index>\n<name>\n<type>\n<base64>`): one pasted file.
import { captureSelection, revealSelection } from './document-selection.js';
import { Editor, getSchema } from '@tiptap/core';
import { createFlightDeckTiptapExtensions } from './sol/docs/editor/prosemirror-flightdeck-schema.js';
import { wikiExtension, insertWikiLink, bindWikiTitle, collectWikiRefs, occurrenceOf, countOf } from './document-wiki.js';
import {
  KeptBlock, KeptInline, KEPT_BLOCK, KEPT_INLINE, scanDocument, preservingExtensions, reuseMap, restoreDocument, nodeTypes,
  markdownSource, markdownFromEditor,
} from './document-preserve.js';

const native = window.webkit?.messageHandlers?.document;
const post = (message) => native?.postMessage(JSON.stringify(message));
const root = document.getElementById('document-root');

/// Paste limits of the app's upload pipeline (sent with `load`); nothing larger or beyond the count is read.
let limits = { maxFileBytes: 100 * 1024 * 1024, maxFiles: 4 };
const files = window.webkit?.messageHandlers?.documentFile;

let editor = null;
let session = null; // { mode, reuse?, markdown?, normalized, knownTypes }
let changeTimer = null;
/// Set by the first user input; plugin adjustments made while the document opens are not edits.
let touched = false;
const images = new Map(); // objectId -> data URL from the app
const requested = new Set();

/// Current titles of the pages links point at (id -> title), pushed by the app, so a renamed page shows its new name.
let wikiTitles = {};

function baseExtensions() {
  return [...createFlightDeckTiptapExtensions({ placeholder: 'Start writing…', editable: true }).map((extension) => {
    // Wiki links: the page only reports a click; the app decides what it opens or creates (and keeps drafts safe first).
    if (extension.name !== 'fdWikiLink') return extension;
    return extension.configure({
      resolve: (attrs) => (attrs.documentId
        ? { state: 'available', title: wikiTitles[attrs.documentId] || attrs.title, page: { record_id: attrs.documentId } }
        : { state: 'unresolved', title: attrs.title }),
      open: (documentId) => post({ type: 'wiki', action: 'activate', documentId, title: wikiTitles[documentId] || '', occurrence: 0 }),
      create: (title, range, ed) => {
        const ref = { title, from: range.from, to: range.to, documentId: null };
        const refs = collectWikiRefs(ed.state.doc);
        post({ type: 'wiki', action: 'activate', documentId: null, title, occurrence: occurrenceOf(refs, ref), count: countOf(refs, ref), from: range.from, to: range.to });
      },
      error: (message) => post({ type: 'wiki', action: 'error', message }),
    });
  }), wikiExtension({ post })];
}

/// The edited document as the app stores it: JSON text (rich) or Markdown.
function output() {
  if (!editor || !session) return null;
  editor.view.domObserver.flush();
  const json = editor.getJSON();
  if (session.mode === 'markdown') return markdownFromEditor(json, session.markdown, session.normalized);
  const restored = restoreDocument(json, session.reuse);
  // Kept atoms always go back as their stored node; a stray one would mean content was being rewritten.
  const types = nodeTypes(restored);
  if (types.has(KEPT_BLOCK) || types.has(KEPT_INLINE)) throw new Error('Kept content could not be restored.');
  return JSON.stringify(restored);
}

function emitChange() {
  clearTimeout(changeTimer);
  changeTimer = null;
  if (!touched) return;
  try {
    post({ type: 'change', content: output() });
  } catch (error) {
    post({ type: 'error', message: String(error?.message || error) });
  }
}

function scheduleChange() {
  clearTimeout(changeTimer);
  changeTimer = setTimeout(emitChange, 250);
}

function activeState() {
  if (!editor) return {};
  const heading = [1, 2, 3, 4].find((level) => editor.isActive('heading', { level })) || 0;
  return {
    bold: editor.isActive('bold'), italic: editor.isActive('italic'), strike: editor.isActive('strike'), code: editor.isActive('code'),
    heading, bulletList: editor.isActive('bulletList'), orderedList: editor.isActive('orderedList'), taskList: editor.isActive('taskList'),
    blockquote: editor.isActive('blockquote'), codeBlock: editor.isActive('codeBlock'), link: editor.getAttributes('link').href || null,
    canUndo: editor.can().undo(), canRedo: editor.can().redo(), selection: !editor.state.selection.empty,
  };
}

let lastState = '';
function emitState() {
  const state = JSON.stringify(activeState());
  post({ type: 'selection', anchor: captureSelection(editor, session?.mode === 'markdown' ? output() : null) });
  if (state === lastState) return;
  lastState = state;
  post({ type: 'state', active: JSON.parse(state) });
}

// MARK: Images

function hydrate(scope = root) {
  for (const img of scope.querySelectorAll('img[data-fd-storage-object-id]')) {
    const id = img.dataset.fdStorageObjectId;
    const url = images.get(id);
    if (url) {
      if (img.getAttribute('src') !== url) img.setAttribute('src', url);
      img.classList.remove('md-storage-image-pending');
    } else if (!requested.has(id)) {
      requested.add(id);
      post({ type: 'need-image', objectId: id });
    }
  }
}

const imageObserver = new MutationObserver(() => hydrate());

// MARK: Paste and drop of files

function base64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/// Files go to the app one per message on their own channel; it strips metadata, stages and uploads them and then
/// asks the page to insert placeholders. Files over the upload limit, or past the per-paste count, are not read.
function handleFiles(list) {
  const all = [...(list || [])].filter(Boolean);
  if (all.length === 0) return false;
  const chosen = all.slice(0, limits.maxFiles);
  const fitting = chosen.filter((file) => file.size <= limits.maxFileBytes);
  post({ type: 'paste-files', count: fitting.length, skipped: all.length - chosen.length, tooLarge: chosen.length - fitting.length });
  (async () => {
    for (const [index, file] of fitting.entries()) {
      const name = String(file.name || '').replace(/\n/g, ' ');
      const type = String(file.type || '').replace(/\n/g, '');
      files?.postMessage(`${index}\n${name}\n${type}\n${base64(await file.arrayBuffer())}`);
    }
  })().catch((error) => post({ type: 'error', message: `Could not read the pasted item: ${error?.message || error}` }));
  return true;
}

// MARK: Load

function mount(message) {
  if (message.limits && Number.isFinite(message.limits.maxFileBytes) && Number.isFinite(message.limits.maxFiles)) {
    limits = { maxFileBytes: message.limits.maxFileBytes, maxFiles: message.limits.maxFiles };
  }
  editor?.destroy();
  editor = null;
  root.textContent = '';
  const base = [...baseExtensions(), KeptBlock, KeptInline];
  let content;
  let extensions = base;
  let next;
  if (message.mode === 'markdown') {
    const markdown = markdownSource(message.markdown ?? '');
    content = markdown.doc;
    next = { mode: 'markdown', markdown };
  } else {
    const stored = message.state;
    const scan = scanDocument(stored, getSchema(base));
    extensions = [...base, ...preservingExtensions(scan)];
    content = scan.prepared;
    next = { mode: 'rich', stored, prepared: scan.prepared };
  }
  const host = document.createElement('div');
  host.className = 'doc-rich-editor';
  root.append(host);
  editor = new Editor({
    element: host,
    extensions,
    content,
    // Stored documents can be outside the schema's content rules (images inside paragraphs, as the web writes them);
    // the web editor loads them as they are, and so does this page.
    enableContentCheck: false,
    editorProps: {
      attributes: { 'aria-label': 'Document text', role: 'textbox', 'aria-multiline': 'true' },
      handleDOMEvents: {
        beforeinput: () => { touched = true; return false; },
        keydown: () => { touched = true; return false; },
        mousedown: () => { touched = true; return false; },
        cut: () => { touched = true; return false; },
        compositionstart: () => { touched = true; return false; },
      },
      handlePaste: (_view, event) => {
        touched = true;
        const files = event.clipboardData?.files;
        if (files && files.length > 0 && handleFiles(files)) { event.preventDefault(); return true; }
        return false;
      },
      handleDrop: (_view, event) => {
        touched = true;
        const files = event.dataTransfer?.files;
        if (files && files.length > 0 && handleFiles(files)) { event.preventDefault(); return true; }
        return false;
      },
    },
    onUpdate: () => { scheduleChange(); emitState(); },
    onSelectionUpdate: emitState,
    onFocus: emitState,
  });
  // The stored document as the schema loaded it, before plugins adjust it on their first transaction (a trailing
  // paragraph after a final table, table repairs): those adjustments are new content, not stored content.
  next.normalized = editor.schema.nodeFromJSON(content).toJSON();
  touched = false;
  if (next.mode === 'rich') next.reuse = reuseMap(next.stored, next.prepared, next.normalized);
  session = next;
  imageObserver.disconnect();
  imageObserver.observe(host, { childList: true, subtree: true });
  hydrate();
  root.dataset.documentEditorState = 'ready';
  emitState();
}

// MARK: Commands

function command(name, args = {}) {
  if (!editor) return false;
  touched = true;
  const chain = editor.chain().focus();
  switch (name) {
    case 'paragraph': return chain.setParagraph().run();
    case 'heading': return chain.toggleHeading({ level: Math.min(4, Math.max(1, Number(args.level) || 1)) }).run();
    case 'bold': return chain.toggleBold().run();
    case 'italic': return chain.toggleItalic().run();
    case 'strike': return chain.toggleStrike().run();
    case 'code': return chain.toggleCode().run();
    case 'bulletList': return chain.toggleBulletList().run();
    case 'orderedList': return chain.toggleOrderedList().run();
    case 'taskList': return chain.toggleTaskList().run();
    case 'blockquote': return chain.toggleBlockquote().run();
    case 'codeBlock': return chain.toggleCodeBlock().run();
    case 'horizontalRule': return chain.setHorizontalRule().run();
    case 'undo': return chain.undo().run();
    case 'redo': return chain.redo().run();
    case 'link': {
      const href = String(args.href || '').trim();
      if (!href) return chain.extendMarkRange('link').unsetLink().run();
      if (editor.state.selection.empty && !editor.isActive('link')) {
        return chain.insertContent({ type: 'text', text: String(args.text || href), marks: [{ type: 'link', attrs: { href } }] }).run();
      }
      return chain.extendMarkRange('link').setLink({ href }).run();
    }
    default: return false;
  }
}

function findUpload(token) {
  let found = null;
  editor.state.doc.descendants((node, pos) => {
    if (found) return false;
    if (node.type.name === 'fdUploadPlaceholder' && node.attrs.uploadId === token) found = { node, pos };
    return !found;
  });
  return found;
}

Object.defineProperty(window, 'ambulandoDocument', {
  value: Object.freeze({
    load(json) {
      try {
        mount(JSON.parse(json));
        post({ type: 'loaded', ok: true });
      } catch (error) {
        root.dataset.documentEditorState = 'error';
        root.textContent = 'The document editor could not open this document.';
        post({ type: 'loaded', ok: false, message: String(error?.message || error) });
      }
      return true;
    },
    command(name, json) { return command(name, json ? JSON.parse(json) : {}); },
    insertUploads(json) {
      if (!editor) return false;
      touched = true;
      const tokens = JSON.parse(json);
      const nodes = tokens.map((token) => ({
        type: 'fdUploadPlaceholder',
        attrs: { uploadId: token, label: token.includes(' file ') ? 'Uploading file…' : 'Uploading image…' },
      }));
      return editor.chain().focus().insertContent(nodes).run();
    },
    /// Replaces an upload placeholder with the uploaded image or file node, or removes it (`node` null).
    replaceUpload(token, json) {
      if (!editor) return false;
      const found = findUpload(token);
      if (!found) return false;
      touched = true;
      const { tr } = editor.state;
      const node = json ? editor.schema.nodeFromJSON(JSON.parse(json)) : null;
      if (node) tr.replaceWith(found.pos, found.pos + found.node.nodeSize, node);
      else tr.delete(found.pos, found.pos + found.node.nodeSize);
      editor.view.dispatch(tr);
      return true;
    },
    setImage(objectId, url) {
      if (!/^data:image\/(png|jpeg|gif|webp|heic);base64,/.test(String(url))) return false;
      images.set(objectId, url);
      hydrate();
      return true;
    },
    setStyle(json) {
      const style = JSON.parse(json);
      for (const [name, value] of Object.entries(style)) {
        if (/^[a-z-]+$/.test(name) && Number.isFinite(value)) document.documentElement.style.setProperty(`--doc-${name}`, `${value}px`);
      }
      return true;
    },
    /// The edited document now (rich: JSON text; Markdown: text), or null before the user changed anything.
    snapshot() {
      clearTimeout(changeTimer);
      changeTimer = null;
      return touched ? output() : null;
    },
    reveal(json) {
      const result = revealSelection(editor, JSON.parse(json), session?.mode === 'markdown' ? output() : null);
      if (result.state === 'found') editor.commands.scrollIntoView();
      return result.state === 'found';
    },
    focus() { editor?.commands.focus(); return true; },
    /// Puts a link where the `[[` query was (or at the selection). `json`: {documentId|null, title, from?, to?}. Returns JSON {occurrence, count} (occurrence -1: bound).
    wikiInsert(json) {
      if (!editor) return null;
      touched = true;
      return JSON.stringify(insertWikiLink(editor, JSON.parse(json)));
    },
    /// A created page's id into this page's unresolved links with that title. `json`: {title, documentId, occurrence|null, expectedCount|null}. Returns how many were bound (-1: the references changed since the request, none bound).
    wikiBind(json) {
      if (!editor) return 0;
      const count = bindWikiTitle(editor, JSON.parse(json));
      if (count > 0) touched = true;
      return count;
    },
    /// Titles of the pages links point at; links redraw with them.
    wikiTitles(json) {
      wikiTitles = JSON.parse(json) || {};
      if (editor) editor.view.dispatch(editor.state.tr.setMeta('wikiRefresh', true).setMeta('addToHistory', false));
      return true;
    },
    /// The selection as the toolbar link command needs it: {from, to, text}.
    wikiSelection() {
      if (!editor) return null;
      const { from, to } = editor.state.selection;
      return JSON.stringify({ from, to, text: editor.state.doc.textBetween(from, to, ' ') });
    },
  }),
});

window.addEventListener('error', (event) => post({ type: 'error', message: String(event.message || 'Script error') }));
post({ type: 'ready' });
