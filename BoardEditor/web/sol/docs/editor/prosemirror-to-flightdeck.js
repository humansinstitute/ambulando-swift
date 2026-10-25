import { wikiSource } from '../wiki-links.js';
import {
  FLIGHTDECK_PROSEMIRROR_CONTENT_FORMAT,
  PROSEMIRROR_JSON_FORMAT,
  PROSEMIRROR_JSON_VERSION,
  createFlightDeckBlockId,
} from './prosemirror-constants.js';

function escapeText(value = '') {
  return String(value || '').replace(/([\\`*_{}\[\]()#+\-.!|>&])/g, '\\$1');
}

function markText(text, marks = [], { atStart = false, atEnd = false, encodeFirst = false, encodeLast = false } = {}) {
  // Markdown emphasis cannot open/close beside literal whitespace, and block
  // parsers trim boundary spaces. Character references preserve the exact text
  // (including its marks) without relaxing the independent integrity check.
  const whitespaceReferences = (value) => Array.from(value, (char) => `&#${char.codePointAt(0)};`).join('');
  // Rich paste includes NBSPs/tabs, not just ASCII spaces. Preserve soft
  // newlines as text too; literal newlines can become Markdown block syntax.
  let escaped = escapeText(text).replace(/[\t\r\n]/g, whitespaceReferences);
  // An encoded marked space ends in ';'. Encode an adjacent word character
  // too, so Markdown's delimiter flanking rules still recognize the mark.
  if (encodeFirst) escaped = escaped.replace(/^[\p{L}\p{N}]/u, (char) => `&#${char.codePointAt(0)};`);
  if (encodeLast) escaped = escaped.replace(/[\p{L}\p{N}]$/u, (char) => `&#${char.codePointAt(0)};`);
  if (marks.length || atStart) escaped = escaped.replace(/^\s+/, whitespaceReferences);
  if (marks.length || atEnd) escaped = escaped.replace(/\s+$/, whitespaceReferences);
  return (marks || []).reduce((out, mark) => {
    if (mark.type === 'bold') return `**${out}**`;
    if (mark.type === 'italic') return `_${out}_`;
    if (mark.type === 'strike') return `~~${out}~~`;
    if (mark.type === 'underline') return `<u>${out}</u>`;
    if (mark.type === 'code') return `\`${String(text || '').replace(/`/g, '\\`')}\``;
    if (mark.type === 'link') return `[${out}](${mark.attrs?.href || ''})`;
    if (mark.type === 'fdMention') {
      const label = mark.attrs?.label || text;
      return `@[${label}](mention:${mark.attrs?.mentionType || 'record'}:${mark.attrs?.mentionId || ''})`;
    }
    return out;
  }, escaped);
}

function inlineMarkdown(nodes = []) {
  // Escaped punctuation reparses into separate text nodes with identical
  // marks. Serialize each contiguous run once so bold/italic delimiters do
  // not collide on reopen (for example **word****\-****word**).
  const runs = [];
  const markOrder = ['code', 'bold', 'italic', 'strike', 'link', 'fdMention', 'underline'];
  for (const source of nodes || []) {
    // Parser nesting and native schema rank can order identical mark sets
    // differently. Choose one wrapper order without mutating the editor JSON.
    const node = source.type === 'text' ? { ...source, marks: [...(source.marks || [])]
      .sort((a, b) => markOrder.indexOf(a.type) - markOrder.indexOf(b.type)) } : source;
    const previous = runs[runs.length - 1];
    if (node.type === 'text' && previous?.type === 'text'
      && JSON.stringify(previous.marks || []) === JSON.stringify(node.marks || [])) {
      previous.text += node.text || '';
    } else {
      runs.push({ ...node });
    }
  }
  const rendered = runs.map((node, index) => {
    if (node.type === 'text') return markText(node.text || '', node.marks || [], {
      atStart: index === 0 || runs[index - 1]?.type === 'hardBreak',
      atEnd: index === runs.length - 1 || runs[index + 1]?.type === 'hardBreak',
      encodeFirst: runs[index - 1]?.marks?.length > 0,
      encodeLast: runs[index + 1]?.marks?.length > 0,
    });
    // Literal Markdown breaks disappear at paragraph boundaries and consecutive
    // breaks become block separators. An inline tag preserves every break.
    if (node.type === 'fdWikiLink') return wikiSource(node.attrs);
    if (node.type === 'hardBreak') return '<br>';
    if (node.type === 'fdStorageImage' || node.type === 'image') {
      const src = node.type === 'fdStorageImage' && node.attrs?.objectId
        ? `storage://${node.attrs.objectId}`
        : node.attrs?.src || (node.attrs?.objectId ? `storage://${node.attrs.objectId}` : '');
      return `![${escapeText(node.attrs?.alt || '')}](${src})`;
    }
    if (node.type === 'fdStorageFile') {
      const src = node.attrs?.src || '';
      const label = node.attrs?.label || node.attrs?.title || src || 'File';
      return `[${escapeText(label)}](${src})`;
    }
    return inlineMarkdown(node.content || []);
  });
  // Keep shared outer marks open across adjacent runs. Closing and reopening
  // italic around a bold-to-plain transition otherwise creates literal '__'.
  const delimiters = { bold: ['**', '**'], italic: ['_', '_'], strike: ['~~', '~~'], underline: ['<u>', '</u>'] };
  for (let index = 1; index < runs.length; index++) {
    if (runs[index - 1].type !== 'text' || runs[index].type !== 'text') continue;
    const left = [...(runs[index - 1].marks || [])].reverse();
    const right = [...(runs[index].marks || [])].reverse();
    let opening = '', closing = '';
    for (let mark = 0; mark < Math.min(left.length, right.length); mark++) {
      const pair = delimiters[left[mark].type];
      if (!pair || JSON.stringify(left[mark]) !== JSON.stringify(right[mark])) break;
      opening += pair[0];
      closing = pair[1] + closing;
    }
    if (opening) {
      rendered[index - 1] = rendered[index - 1].slice(0, -closing.length);
      rendered[index] = rendered[index].slice(opening.length);
    }
  }
  return rendered.join('');
}

function indent(value = '', spaces = 2) {
  const prefix = ' '.repeat(spaces);
  return String(value || '').split('\n').map((line) => `${prefix}${line}`).join('\n');
}

function listMarkdown(node = {}, ordered = false) {
  return (node.content || []).map((item, index) => {
    const marker = node.type === 'taskList'
      ? `- [${item.attrs?.checked ? 'x' : ' '}]`
      : ordered ? `${index + (node.attrs?.start || 1)}.` : '-';
    // Every child belongs to the item, in order. Rich editors can create
    // multiple paragraphs, headings and quotes as well as nested lists.
    // Continuations align with the content after the actual Markdown marker
    // (including multi-digit numbers); a task checkbox is part of that content.
    const width = node.type === 'taskList' ? 2 : marker.length + 1;
    const body = blockNodesMarkdown(item.content || []);
    const [first = '', ...rest] = body.split('\n');
    return `${marker} ${first}${rest.length ? `\n${indent(rest.join('\n'), width)}` : ''}`;
  }).join('\n');
}

function tableMarkdown(node = {}) {
  const rows = node.content || [];
  if (rows.length === 0) return '';
  const cells = rows.map((row) => (row.content || []).map((cell) => inlineMarkdown(cell.content?.[0]?.content || [])));
  const width = Math.max(...cells.map((row) => row.length), 1);
  const normalize = (row) => Array.from({ length: width }, (_, index) => row[index] || '');
  const lines = [];
  const header = normalize(cells[0] || []);
  lines.push(`| ${header.join(' | ')} |`);
  lines.push(`| ${header.map(() => '---').join(' | ')} |`);
  for (const row of cells.slice(1)) lines.push(`| ${normalize(row).join(' | ')} |`);
  return lines.join('\n');
}

function blockMarkdown(node = {}) {
  if (node.type === 'heading') return `${'#'.repeat(node.attrs?.level || 1)} ${inlineMarkdown(node.content || [])}`.trimEnd();
  if (node.type === 'paragraph') return inlineMarkdown(node.content || []);
  if (node.type === 'codeBlock') {
    const language = node.attrs?.language || '';
    const text = (node.content || []).map((child) => child.text || '').join('');
    return `\`\`\`${language}\n${text}\n\`\`\``;
  }
  if (node.type === 'blockquote') {
    return blockNodesMarkdown(node.content || []).split('\n').map((line) => `> ${line}`.trimEnd()).join('\n');
  }
  if (node.type === 'horizontalRule') return '---';
  if (node.type === 'bulletList' || node.type === 'taskList') return listMarkdown(node, false);
  if (node.type === 'orderedList') return listMarkdown(node, true);
  if (node.type === 'table') return tableMarkdown(node);
  if (node.type === 'fdStorageImage' || node.type === 'image') return inlineMarkdown([node]);
  if (node.type === 'fdStorageFile') return inlineMarkdown([node]);
  if (node.type === 'fdUploadPlaceholder') return '';
  return inlineMarkdown(node.content || []);
}

function blockNodesMarkdown(nodes = []) {
  return (nodes || []).map(blockMarkdown).filter((value) => String(value || '').trim()).join('\n\n');
}

function compatibilityBlockType(node = {}) {
  if (node.type === 'heading') return 'heading';
  if (node.type === 'paragraph') return 'paragraph';
  if (node.type === 'codeBlock') return 'code';
  if (node.type === 'bulletList' || node.type === 'orderedList' || node.type === 'taskList') return 'list';
  return node.type || 'markdown';
}

function blockIdForNode(node = {}) {
  return String(node.attrs?.fdBlockId || node.attrs?.id || '').trim() || createFlightDeckBlockId();
}

export function prosemirrorToFlightDeckContentModel(editorState = {}) {
  const state = editorState?.type === 'doc' ? editorState : { type: 'doc', content: [] };
  const content = blockNodesMarkdown(state.content || []);
  const contentBlocks = (state.content || []).map((node) => {
    const id = blockIdForNode(node);
    const raw = blockMarkdown(node);
    return {
      id,
      type: compatibilityBlockType(node),
      text: raw,
      attrs: {
        ...(node.attrs && typeof node.attrs === 'object' ? node.attrs : {}),
        pmNodeId: id,
      },
    };
  }).filter((block) => String(block.text || '').trim());

  return {
    content,
    content_format: FLIGHTDECK_PROSEMIRROR_CONTENT_FORMAT,
    content_blocks: contentBlocks,
    editor_state: state,
    editor_state_format: PROSEMIRROR_JSON_FORMAT,
    editor_state_version: PROSEMIRROR_JSON_VERSION,
  };
}
