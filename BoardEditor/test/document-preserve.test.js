// Round trips of the document editor's preservation layer (web/document-preserve.js), in the editor's own schema.
// Run: `bun test` in BoardEditor/.
import { test, expect } from 'bun:test';
import { getSchema } from '@tiptap/core';
import { Node as PMNode } from '@tiptap/pm/model';
import { EditorState } from '@tiptap/pm/state';
import { createFlightDeckTiptapExtensions } from '../web/sol/docs/editor/prosemirror-flightdeck-schema.js';
import {
  KeptBlock, KeptInline, scanDocument, preservingExtensions, reuseMap, restoreDocument, markdownSource, markdownFromEditor,
} from '../web/document-preserve.js';

const base = [...createFlightDeckTiptapExtensions({ editable: true }), KeptBlock, KeptInline];
const baseSchema = getSchema(base);

const stored = {
  type: 'doc',
  content: [
    { type: 'heading', attrs: { level: 1, fdBlockId: 'pm_h', futureAlign: 'center' }, content: [{ type: 'text', text: 'Title' }] },
    { type: 'paragraph', attrs: { fdBlockId: 'pm_p1' }, content: [
      { type: 'text', text: 'Hello ' },
      { type: 'text', text: 'world', marks: [{ type: 'link', attrs: { href: 'https://x.test' } }, { type: 'bold' }] },
      { type: 'text', text: ' and ', marks: [{ type: 'highlightX', attrs: { color: 'red' } }] },
      { type: 'futureInline', attrs: { id: 7 } },
    ] },
    { type: 'futureBlock', attrs: { a: 1 }, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'nested' }] }] },
    { type: 'fdStorageImage', attrs: { src: 'storage://11111111-1111-1111-1111-111111111111', objectId: '11111111-1111-1111-1111-111111111111', alt: 'pic', title: 'pic' } },
    { type: 'paragraph', attrs: { fdBlockId: 'pm_p2' }, content: [{ type: 'fdStorageImage', attrs: { objectId: '22222222-2222-2222-2222-222222222222', alt: 'inline' } }] },
    { type: 'taskList', attrs: { fdBlockId: 'pm_t' }, content: [{ type: 'taskItem', attrs: { checked: true, extra: 'x' }, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'done' }] }] }] },
    { type: 'table', attrs: { fdBlockId: 'pm_tb' }, content: [{ type: 'tableRow', content: [{ type: 'tableHeader', attrs: { colspan: 1, rowspan: 1, colwidth: null }, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'A' }] }] }] }] },
  ],
};

/// What the page does: scan, build the schema for this document, load, normalise, pair.
function open(doc) {
  const scan = scanDocument(doc, baseSchema);
  const schema = getSchema([...base, ...preservingExtensions(scan)]);
  const pm = PMNode.fromJSON(schema, scan.prepared);
  const normalized = pm.toJSON();
  return { schema, pm, reuse: reuseMap(doc, scan.prepared, normalized), normalized };
}

function blockStart(pm, index) {
  let pos = 0;
  pm.forEach((_node, offset, i) => { if (i === index) pos = offset; });
  return pos;
}

test('an unchanged document is restored byte for byte', () => {
  const { pm, reuse } = open(stored);
  expect(JSON.stringify(restoreDocument(pm.toJSON(), reuse))).toBe(JSON.stringify(stored));
});

test('typing in one paragraph keeps every other block, unknown nodes, marks and attributes', () => {
  const { schema, pm, reuse } = open(stored);
  let state = EditorState.create({ schema, doc: pm });
  state = state.apply(state.tr.insertText('X', blockStart(pm, 1) + 1));
  const out = restoreDocument(state.doc.toJSON(), reuse);
  for (const i of [0, 2, 3, 4, 5, 6]) expect(out.content[i]).toBe(stored.content[i]);
  const p = out.content[1];
  expect(p.attrs).toEqual({ fdBlockId: 'pm_p1' });
  expect(p.content[0]).toEqual({ type: 'text', text: 'XHello ' });
  expect(p.content[1]).toBe(stored.content[1].content[1]);
  expect(p.content[2]).toBe(stored.content[1].content[2]);
  expect(p.content[3]).toEqual(stored.content[1].content[3]);
});

test('formatting new text uses the web schema; an edited block keeps its unknown attributes and stored marks', () => {
  const { schema, pm, reuse } = open(stored);
  let state = EditorState.create({ schema, doc: pm });
  state = state.apply(state.tr.insertText('!', blockStart(pm, 0) + 6));
  state = state.apply(state.tr.addMark(blockStart(pm, 0) + 1, blockStart(pm, 0) + 3, schema.marks.bold.create()));
  // Extend the stored link text: the link mark keeps its stored JSON (no defaults added).
  const link = blockStart(state.doc, 1) + 1 + 'Hello '.length + 2;
  state = state.apply(state.tr.insertText('Z', link));
  const out = restoreDocument(state.doc.toJSON(), reuse);
  expect(out.content[0].attrs).toEqual({ level: 1, fdBlockId: 'pm_h', futureAlign: 'center' });
  expect(out.content[0].content[0]).toEqual({ type: 'text', text: 'Ti', marks: [{ type: 'bold' }] });
  expect(out.content[0].content[1]).toEqual({ type: 'text', text: 'tle!' });
  const linked = out.content[1].content[1];
  expect(linked.text).toBe('woZrld');
  expect(linked.marks).toEqual(stored.content[1].content[1].marks);
  expect(linked.marks.find((m) => m.type === 'link')).toBe(stored.content[1].content[1].marks[0]);
});

test('unknown nodes are kept as atoms and are never rewritten; deleting one is the only way it leaves', () => {
  const { schema, pm, reuse } = open(stored);
  expect(pm.child(2).type.name).toBe('fdKeptBlock');
  expect(pm.child(1).lastChild.type.name).toBe('fdKeptInline');
  let state = EditorState.create({ schema, doc: pm });
  const start = blockStart(pm, 2);
  state = state.apply(state.tr.delete(start, start + pm.child(2).nodeSize));
  const out = restoreDocument(state.doc.toJSON(), reuse);
  expect(out.content.some((n) => n.type === 'futureBlock')).toBe(false);
  expect(out.content.length).toBe(stored.content.length - 1);
  expect(out.content[1]).toBe(stored.content[1]);
});

test('a document reopened from a draft keeps the stored JSON it carried', () => {
  const first = open(stored);
  let state = EditorState.create({ schema: first.schema, doc: first.pm });
  state = state.apply(state.tr.insertText('Y', blockStart(first.pm, 1) + 1));
  const draft = JSON.parse(JSON.stringify(restoreDocument(state.doc.toJSON(), first.reuse)));
  const second = open(draft);
  expect(JSON.stringify(restoreDocument(second.pm.toJSON(), second.reuse))).toBe(JSON.stringify(draft));
  expect(draft.content[2]).toEqual(stored.content[2]);
});

const markdown = `# Install

Intro paragraph with **bold**, a [link](https://example.test) and \`code\`.

* star bullet
* second

1) paren list
2) two

| a | b |
|---|---|
| 1 | 2 |

\`\`\`sh
git clone x
\`\`\`

> quote

![shot](storage://33333333-3333-3333-3333-333333333333)

[[Wiki Page]]

Last line
`;

function openMarkdown(source) {
  const session = markdownSource(source);
  const pm = PMNode.fromJSON(baseSchema, session.doc);
  return { session, pm, normalized: pm.toJSON() };
}

test('an unchanged Markdown document returns its source exactly', () => {
  const { session, pm, normalized } = openMarkdown(markdown);
  expect(session.blocks).not.toBeNull();
  expect(markdownFromEditor(pm.toJSON(), session, normalized)).toBe(markdown);
});

test('editing one Markdown block keeps the source of the others (bullet style, list delimiter, table layout)', () => {
  const { session, pm, normalized } = openMarkdown(markdown);
  let state = EditorState.create({ schema: baseSchema, doc: pm });
  state = state.apply(state.tr.insertText(' more', blockStart(pm, 1) + 1 + 'Intro paragraph'.length));
  state = state.apply(state.tr.addMark(blockStart(pm, 1) + 1, blockStart(pm, 1) + 6, baseSchema.marks.italic.create()));
  const out = markdownFromEditor(state.doc.toJSON(), session, normalized);
  // The edited block is written by the web serializer; every other block keeps its source.
  expect(out).toBe(markdown.replace('Intro paragraph with **bold**, a [link](https://example.test) and `code`.',
    '_Intro_ paragraph more with **bold**, a [link](https://example.test) and `code`\\.'));
});

test('new Markdown blocks are serialised as the web does, and upload placeholders stay as tokens', () => {
  const token = '[ Uploading image 0a1b2c3d-0000-4000-8000-000000000000... ]';
  const { session, pm, normalized } = openMarkdown(`Para one\n\n${token}\n`);
  expect(pm.child(1).type.name).toBe('fdUploadPlaceholder');
  let state = EditorState.create({ schema: baseSchema, doc: pm });
  const heading = baseSchema.nodes.heading.create({ level: 2 }, baseSchema.text('New'));
  state = state.apply(state.tr.insert(state.doc.content.size, heading));
  expect(markdownFromEditor(state.doc.toJSON(), session, normalized)).toBe(`Para one\n\n${token}\n\n## New\n`);
});

test('raw Markdown without a trailing newline, and an emptied document', () => {
  const { session, pm, normalized } = openMarkdown('one\n\ntwo');
  expect(markdownFromEditor(pm.toJSON(), session, normalized)).toBe('one\n\ntwo');
  const empty = { type: 'doc', content: [{ type: 'paragraph' }] };
  expect(markdownFromEditor(empty, session, normalized)).toBe('');
});

test('a paragraph the editor appends after a final table (trailing node) does not disturb stored content', () => {
  const source = 'Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n';
  const { session, pm, normalized } = openMarkdown(source);
  let state = EditorState.create({ schema: baseSchema, doc: pm });
  state = state.apply(state.tr.insert(state.doc.content.size, baseSchema.nodes.paragraph.create()));
  expect(markdownFromEditor(state.doc.toJSON(), session, normalized)).toBe(source);

  const rich = open(stored);
  let edited = EditorState.create({ schema: rich.schema, doc: rich.pm });
  edited = edited.apply(edited.tr.insert(edited.doc.content.size, rich.schema.nodes.paragraph.create()));
  const out = restoreDocument(edited.doc.toJSON(), rich.reuse);
  expect(out.content.slice(0, stored.content.length)).toEqual(stored.content);
  stored.content.forEach((node, i) => expect(out.content[i]).toBe(node));
});
