// Lossless editing of stored Flight Deck documents in the web editor's schema (sol `prosemirror-flightdeck-schema.js`).
//
// The schema knows only the node types, marks and attributes the web editor defines; a stored document can hold more
// (a newer web version, another client). Loading it straight into ProseMirror would drop them. So:
// - node types the schema does not know become opaque atoms carrying the stored JSON (`fdKeptBlock` / `fdKeptInline`),
//   shown as a small "kept" chip that can be moved or deleted but not changed;
// - unknown attributes of known nodes and marks, and unknown marks, are added to the schema for this document only, so
//   ProseMirror carries them like its own;
// - every node (and mark) of the edited document whose normalised JSON equals the normalised JSON of a stored one is
//   written back as the stored JSON, so untouched content is identical to what was stored.
//
// Markdown documents are edited in the same schema (sol `markdownToProseMirrorDoc`) and saved as Markdown: top-level
// blocks the user did not change keep their exact source text and the whitespace between them.
import { Extension, Mark, Node } from '@tiptap/core';
import { Lexer } from 'marked';
import { markdownToProseMirrorDoc } from './sol/docs/editor/markdown-to-prosemirror.js';
import { prosemirrorToFlightDeckContentModel } from './sol/docs/editor/prosemirror-to-flightdeck.js';

export const KEPT_BLOCK = 'fdKeptBlock';
export const KEPT_INLINE = 'fdKeptInline';
const UPLOAD = 'fdUploadPlaceholder';
/// Native upload placeholders (`UploadToken.make`): `[ Uploading image <id>... ]`.
const UPLOAD_TOKEN = /^\[ Uploading (?:image|file) [A-Za-z0-9-]+(?:\.\.\.|…) \]$/;

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const key = (value) => JSON.stringify(value);

function keptLabel(json) {
  try { return `${String(JSON.parse(json)?.type || 'Content')} — kept unchanged`; } catch { return 'Content — kept unchanged'; }
}

export const KeptBlock = Node.create({
  name: KEPT_BLOCK,
  group: 'block',
  atom: true,
  selectable: true,
  addAttributes() { return { json: { default: null, rendered: false } }; },
  parseHTML() { return []; },
  renderHTML({ node }) {
    return ['div', { class: 'fd-kept fd-kept-block', 'data-fd-kept': '', contenteditable: 'false' }, keptLabel(node.attrs.json)];
  },
});

export const KeptInline = Node.create({
  name: KEPT_INLINE,
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  addAttributes() { return { json: { default: null, rendered: false } }; },
  parseHTML() { return []; },
  renderHTML({ node }) {
    return ['span', { class: 'fd-kept fd-kept-inline', 'data-fd-kept': '', contenteditable: 'false' }, keptLabel(node.attrs.json)];
  },
});

/// What the stored document holds beyond `schema` (a schema built from the base extensions plus the kept atoms), and
/// the document with unknown nodes replaced by kept atoms.
export function scanDocument(doc, schema) {
  const extraAttrs = new Map(); // node or mark type -> Set(attribute)
  const unknownMarks = new Map(); // mark type -> Set(attribute)
  const note = (map, type, attr) => {
    if (!map.has(type)) map.set(type, new Set());
    if (attr !== undefined) map.get(type).add(attr);
  };
  const attrKeys = (value) => Object.keys(isObject(value?.attrs) ? value.attrs : {});

  function scanMarks(marks) {
    for (const mark of Array.isArray(marks) ? marks : []) {
      const type = String(mark?.type || '');
      const known = schema.marks[type];
      if (!known) {
        note(unknownMarks, type);
        attrKeys(mark).forEach((attr) => note(unknownMarks, type, attr));
      } else {
        attrKeys(mark).filter((attr) => !(attr in known.attrs)).forEach((attr) => note(extraAttrs, type, attr));
      }
    }
  }

  function prepare(node, inlineContext) {
    if (!isObject(node)) return node;
    const type = String(node.type || '');
    const known = schema.nodes[type];
    if (!known || type === KEPT_BLOCK || type === KEPT_INLINE || type === 'doc' || type === 'text' && typeof node.text !== 'string') {
      return { type: inlineContext ? KEPT_INLINE : KEPT_BLOCK, attrs: { json: JSON.stringify(node) } };
    }
    attrKeys(node).filter((attr) => !(attr in known.attrs)).forEach((attr) => note(extraAttrs, type, attr));
    scanMarks(node.marks);
    if (!Array.isArray(node.content)) return node;
    return { ...node, content: node.content.map((child) => prepare(child, known.inlineContent)) };
  }

  const content = isObject(doc) && doc.type === 'doc' && Array.isArray(doc.content) ? doc.content : [];
  const prepared = { ...(isObject(doc) ? doc : {}), type: 'doc', content: content.map((child) => prepare(child, false)) };
  return { prepared, extraAttrs, unknownMarks };
}

const keptAttribute = { default: undefined, rendered: false, keepOnSplit: false };

/// Schema additions for what this document holds beyond the web schema. Kept marks never match pasted HTML.
export function preservingExtensions({ extraAttrs, unknownMarks }) {
  const extensions = [...unknownMarks.entries()].map(([name, attrs]) => Mark.create({
    name,
    parseHTML() { return []; },
    renderHTML() { return ['span', { 'data-fd-kept-mark': name }, 0]; },
    addAttributes() { return Object.fromEntries([...attrs].map((attr) => [attr, keptAttribute])); },
  }));
  if (extraAttrs.size > 0) {
    extensions.push(Extension.create({
      name: 'fdKeptAttributes',
      addGlobalAttributes() {
        return [...extraAttrs.entries()].map(([type, attrs]) => ({
          types: [type],
          attributes: Object.fromEntries([...attrs].map((attr) => [attr, keptAttribute])),
        }));
      },
    }));
  }
  return extensions;
}

/// Pairs the stored document with the editor's normalised form of it (`prepared` is the stored document with kept
/// atoms, as given to the editor). Normalised node JSON maps to the stored node; normalised mark JSON to the stored mark.
export function reuseMap(stored, prepared, normalized) {
  const nodes = new Map();
  const marks = new Map();
  function pair(original, prep, norm) {
    if (!isObject(prep) || !isObject(norm) || prep.type !== norm.type) return;
    const k = key(norm);
    if (!nodes.has(k)) nodes.set(k, original);
    const om = Array.isArray(original?.marks) ? original.marks : [];
    for (const mark of Array.isArray(norm.marks) ? norm.marks : []) {
      // ProseMirror orders marks by schema rank, so pair them by type.
      const stored = om.find((m) => m?.type === mark.type);
      const mk = key(mark);
      if (stored && !marks.has(mk)) marks.set(mk, stored);
    }
    const o = Array.isArray(original?.content) ? original.content : [];
    const a = Array.isArray(prep.content) ? prep.content : [];
    const b = Array.isArray(norm.content) ? norm.content : [];
    if (o.length !== a.length || a.length !== b.length) return;
    for (let i = 0; i < a.length; i += 1) pair(o[i], a[i], b[i]);
  }
  pair(stored, prepared, normalized);
  return { nodes, marks };
}

const definedAttrs = (attrs) => Object.fromEntries(Object.entries(attrs).filter(([, value]) => value !== undefined));

/// The edited document for storage: stored JSON wherever content is unchanged, kept atoms back to their stored JSON,
/// and no attributes the document never had.
export function restoreDocument(edited, reuse) {
  function emit(node) {
    if (!isObject(node)) return node;
    const hit = reuse.nodes.get(key(node));
    if (hit !== undefined) return hit;
    if (node.type === KEPT_BLOCK || node.type === KEPT_INLINE) return JSON.parse(node.attrs.json);
    const out = { ...node };
    if (isObject(node.attrs)) out.attrs = definedAttrs(node.attrs);
    if (Array.isArray(node.marks)) {
      out.marks = node.marks.map((mark) => {
        const stored = reuse.marks.get(key(mark));
        if (stored !== undefined) return stored;
        return isObject(mark.attrs) ? { ...mark, attrs: definedAttrs(mark.attrs) } : mark;
      });
    }
    if (Array.isArray(node.content)) out.content = node.content.map(emit);
    return out;
  }
  return emit(edited);
}

/// Node types in `doc` (recursively).
export function nodeTypes(doc, into = new Set()) {
  if (!isObject(doc)) return into;
  into.add(String(doc.type || ''));
  for (const child of Array.isArray(doc.content) ? doc.content : []) nodeTypes(child, into);
  return into;
}

// MARK: Markdown

/// Placeholder paragraphs (`[ Uploading image <id>... ]`) become upload nodes, as the editor shows them.
function withUploads(doc) {
  return {
    ...doc,
    content: doc.content.map((node) => {
      const text = node.type === 'paragraph' && node.content?.length === 1 && node.content[0].type === 'text' && !node.content[0].marks
        ? node.content[0].text : null;
      return text && UPLOAD_TOKEN.test(text)
        ? { type: UPLOAD, attrs: { uploadId: text, label: text.includes('file') ? 'Uploading file…' : 'Uploading image…' } }
        : node;
    }),
  };
}

/// A Markdown body as an editor document plus the source of each top-level block.
export function markdownSource(source) {
  const text = String(source ?? '');
  const doc = withUploads(markdownToProseMirrorDoc(text));
  const tokens = new Lexer().lex(text);
  // Source text of each block, the whitespace between blocks and the whitespace at either end.
  const blocks = [];
  let gap = '';
  let lead = null;
  for (const token of tokens) {
    if (token.type === 'space') { gap += token.raw; continue; }
    const raw = String(token.raw || '');
    const body = raw.replace(/\s+$/, '');
    if (lead === null) lead = gap;
    else if (blocks.length) blocks[blocks.length - 1].after = gap;
    blocks.push({ body, after: '' });
    gap = raw.slice(body.length);
  }
  const trail = gap;
  // The lexer's blocks must be exactly the editor's blocks, and must rebuild the source; otherwise nothing is reused.
  const rebuilt = (lead ?? '') + blocks.map((b, i) => b.body + (i < blocks.length - 1 ? b.after : '')).join('') + trail;
  const aligned = blocks.length === doc.content.length && rebuilt === text;
  return { doc, blocks: aligned ? blocks : null, lead: lead ?? '', trail, source: text };
}

/// Markdown for one edited top-level node (sol's serializer; upload placeholders stay as their token).
function nodeMarkdown(node) {
  if (node?.type === UPLOAD) return String(node.attrs?.uploadId || '');
  return prosemirrorToFlightDeckContentModel({ type: 'doc', content: [node] }).content;
}

/// Markdown for the edited document: stored source for unchanged blocks (in their original order and spacing), the
/// web serializer for the rest. An unchanged document returns its source exactly.
export function markdownFromEditor(edited, session, normalized) {
  const content = Array.isArray(edited?.content) ? edited.content : [];
  const { blocks } = session;
  if (!blocks) return prosemirrorToFlightDeckContentModel(edited).content;
  const index = new Map();
  (normalized.content || []).forEach((node, i) => {
    if (i >= blocks.length) return;
    const k = key(node);
    if (!index.has(k)) index.set(k, []);
    index.get(k).push(i);
  });
  let out = '';
  let previous = null;
  let used = -1;
  let first = true;
  for (const node of content) {
    const candidates = index.get(key(node)) || [];
    const j = candidates.find((i) => i > used);
    const piece = j !== undefined ? blocks[j].body : nodeMarkdown(node);
    if (!String(piece).trim()) { previous = null; continue; }
    if (first) { out += j === 0 ? session.lead : ''; first = false; }
    else out += previous !== null && j === previous + 1 ? blocks[previous].after : '\n\n';
    out += piece;
    if (j !== undefined) used = j;
    previous = j !== undefined ? j : null;
  }
  return out + (out ? session.trail : '');
}
