// Regenerates prosemirror-golden.json from the web client's own serializer, so the Swift port
// (ProseMirrorMarkdown) is checked against sol's output byte for byte.
// Usage: node generate-prosemirror-golden.mjs <path-to-sol> > prosemirror-golden.json
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';

const sol = process.argv[2];
if (!sol) throw new Error('usage: node generate-prosemirror-golden.mjs <path-to-sol>');
const { prosemirrorToFlightDeckContentModel } = await import(pathToFileURL(join(sol, 'src/docs/editor/prosemirror-to-flightdeck.js')).href);

const t = (text, marks) => (marks ? { type: 'text', text, marks } : { type: 'text', text });
const p = (id, ...content) => ({ type: 'paragraph', attrs: { fdBlockId: id }, content });
const b = { type: 'bold' }, i = { type: 'italic' }, s = { type: 'strike' }, u = { type: 'underline' }, c = { type: 'code' };
const link = (href) => ({ type: 'link', attrs: { href, target: '_blank', rel: 'noopener', class: null } });
const cases = {
  plain: [p('b1', t('Hello world.'))],
  escapes: [p('b1', t('a*b_c [x](y) #1 > q | 2+2-1! & `tick` \\ {}'))],
  marks: [p('b1', t('plain '), t('bold', [b]), t(' and '), t('both', [b, i]), t(' '), t('struck', [s]), t('under', [u]))],
  sharedOuter: [p('b1', t('one ', [i]), t('two', [b, i]), t(' three', [i]))],
  boundaryWhitespace: [p('b1', t(' lead', [b]), t('trail ', [b, i]), t(' nbsp\t', [i]))],
  adjacentWordMarks: [p('b1', t('word', [b]), t('-'), t('word', [b]), t('x'), t('y', [i]))],
  code: [p('b1', t('use '), t('a`b', [c]), t(' here'))],
  links: [p('b1', t('see '), t('docs', [link('https://example.com/a?b=c')]), t(' now'))],
  mention: [p('b1', t('hi '), t('Ana', [{ type: 'fdMention', attrs: { mentionType: 'person', mentionId: 'npub1abc', label: 'Ana' } }]))],
  wiki: [p('b1', { type: 'fdWikiLink', attrs: { documentId: 'doc/1 2', title: 'Plan [v2]' } }, t(' and '), { type: 'fdWikiLink', attrs: { title: 'Unbound' } })],
  hardBreaks: [p('b1', t('line one'), { type: 'hardBreak' }, t('line two '), { type: 'hardBreak' }, { type: 'hardBreak' }, t('three'))],
  headings: [{ type: 'heading', attrs: { level: 2, fdBlockId: 'h1' }, content: [t('Title '), t('x', [b])] }, { type: 'heading', attrs: { level: 1, fdBlockId: 'h2' }, content: [] }],
  codeBlock: [{ type: 'codeBlock', attrs: { language: 'swift', fdBlockId: 'c1' }, content: [t('let x = 1\n// `a`')] }],
  quote: [{ type: 'blockquote', attrs: { fdBlockId: 'q1' }, content: [p(null, t('quoted')), { type: 'bulletList', content: [{ type: 'listItem', content: [p(null, t('inner'))] }] }] }],
  lists: [
    { type: 'bulletList', attrs: { fdBlockId: 'l1' }, content: [
      { type: 'listItem', content: [p(null, t('one')), p(null, t('second para'))] },
      { type: 'listItem', content: [p(null, t('two')), { type: 'orderedList', attrs: { start: 1 }, content: [{ type: 'listItem', content: [p(null, t('nested'))] }] }] }] },
    { type: 'orderedList', attrs: { start: 9, fdBlockId: 'l2' }, content: [{ type: 'listItem', content: [p(null, t('nine'))] }, { type: 'listItem', content: [p(null, t('ten'), { type: 'hardBreak' }, t('more'))] }] },
    { type: 'taskList', attrs: { fdBlockId: 'l3' }, content: [{ type: 'taskItem', attrs: { checked: true }, content: [p(null, t('done'))] }, { type: 'taskItem', attrs: { checked: false }, content: [p(null, t('todo'))] }] },
  ],
  table: [{ type: 'table', attrs: { fdBlockId: 't1' }, content: [
    { type: 'tableRow', content: [{ type: 'tableHeader', content: [p(null, t('A'))] }, { type: 'tableHeader', content: [p(null, t('B', [b]))] }] },
    { type: 'tableRow', content: [{ type: 'tableCell', content: [p(null, t('1'))] }] }] }],
  media: [p('b1', { type: 'fdStorageImage', attrs: { objectId: '11111111-2222-4333-8444-555555555555', alt: 'A [pic]' } }),
    { type: 'image', attrs: { src: 'https://img.example/x.png', alt: '' } },
    p('b3', { type: 'fdStorageFile', attrs: { src: 'storage://abc', label: 'Report.pdf' } })],
  misc: [{ type: 'horizontalRule', attrs: { fdBlockId: 'r1' } }, p('e1'), { type: 'fdUploadPlaceholder', attrs: { label: 'x' } },
    { type: 'customWidget', attrs: { fdBlockId: 'w1', payload: { n: 1.50 } }, content: [t('inside custom')] }],
  unicode: [p('b1', t('café '), t('émph', [b]), t(' 🎉👍🏽 '), t('日本', [i]), t('語'))],
  unknownMark: [p('b1', t('x', [{ type: 'highlight', attrs: { color: 'yellow' } }, b]), t('y'))],
};

const out = {};
for (const [name, content] of Object.entries(cases)) {
  const state = { type: 'doc', content };
  const model = prosemirrorToFlightDeckContentModel(state);
  out[name] = { state, content: model.content, blocks: model.content_blocks.map(({ id, type, text }) => ({ id, type, text })) };
}
process.stdout.write(JSON.stringify(out, null, 1));
