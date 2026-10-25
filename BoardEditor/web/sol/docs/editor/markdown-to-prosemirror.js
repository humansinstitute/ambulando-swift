import { Marked } from 'marked';
const marked = new Marked();
import { normalizeDocumentBlocks } from '../../utils/state-helpers.js';
import { createFlightDeckBlockId } from './prosemirror-constants.js';

marked.use({ extensions: [{
  name: 'fdWiki', level: 'inline',
  start: (src) => src.indexOf('[['),
  tokenizer(src) {
    const match = /^\[\[([^\]\n]+)\]\]/.exec(src);
    if (match) return { type: 'fdWiki', raw: match[0], title: match[1] };
  },
}] });

function textNode(text, marks = []) {
  const value = String(text || '');
  if (!value) return null;
  return marks.length > 0 ? { type: 'text', text: value, marks } : { type: 'text', text: value };
}

function paragraphFromText(text, attrs = {}) {
  const node = { type: 'paragraph', attrs };
  const child = textNode(text);
  if (child) node.content = [child];
  return node;
}

function marksForToken(token = {}) {
  const marks = [];
  if (token.type === 'strong') marks.push({ type: 'bold' });
  if (token.type === 'em') marks.push({ type: 'italic' });
  if (token.type === 'del') marks.push({ type: 'strike' });
  if (token.type === 'codespan') marks.push({ type: 'code' });
  if (token.type === 'link') marks.push({ type: 'link', attrs: { href: token.href, title: token.title || null } });
  return marks;
}

function mentionPartsFromHref(href = '') {
  const match = String(href || '').match(/^mention:([^:()]+):(.+)$/);
  if (!match) return null;
  return {
    mentionType: match[1],
    mentionId: match[2],
  };
}

function mentionMarkFromText(text) {
  const match = String(text || '').match(/^@\[([^\]]+)]\(mention:([^:()]+):([^)]+)\)$/);
  if (!match) return null;
  return {
    type: 'fdMention',
    attrs: {
      label: match[1],
      mentionType: match[2],
      mentionId: match[3],
    },
  };
}

function textFromInlineToken(token = {}) {
  if (typeof token.text === 'string') return token.text;
  if (Array.isArray(token.tokens)) return token.tokens.map(textFromInlineToken).join('');
  return String(token.raw || '');
}

function pushTextNode(out, text, marks = []) {
  const node = textNode(text, marks);
  if (node) out.push(node);
}

function consumeMentionMarker(out = []) {
  const last = out[out.length - 1];
  if (!last || last.type !== 'text' || typeof last.text !== 'string' || !last.text.endsWith('@')) return false;
  const nextText = last.text.slice(0, -1);
  if (nextText) {
    last.text = nextText;
  } else {
    out.pop();
  }
  return true;
}

function inlineContent(tokens = [], inheritedMarks = []) {
  const out = [];
  let underline = false;
  for (const token of tokens || []) {
    if (!token) continue;
    if (token.type === 'fdWiki' || (token.type === 'link' && String(token.href).startsWith('wiki:'))) {
      let documentId = null;
      if (token.href) {
        try { documentId = decodeURIComponent(token.href.slice(5)); } catch { documentId = token.href.slice(5); }
      }
      out.push({ type: 'fdWikiLink', attrs: { documentId, title: token.type === 'fdWiki' ? token.title : inlineContent(token.tokens || [{ type: 'text', text: token.text || '' }]).map((node) => node.text || '').join('') } });
      continue;
    }
    if (token.type === 'html' && /^<br\s*\/?\s*>$/i.test(token.raw)) {
      out.push({ type: 'hardBreak' });
      continue;
    }
    if (token.type === 'html' && /^<\/?u>$/i.test(token.raw)) {
      underline = !/^<\/u>$/i.test(token.raw);
      continue;
    }
    const activeMarks = underline ? [...inheritedMarks, { type: 'underline' }] : inheritedMarks;
    if (token.type === 'text' || token.type === 'escape') {
      const mention = mentionMarkFromText(token.text);
      // Decode decimal character references in prose only, after lexing. Escaped
      // ampersands and code tokens must stay literal (no recursive decoding).
      const text = token.type === 'text' ? token.text.replace(/&#(\d+);/g, (raw, digits) => {
        const code = Number(digits);
        return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff)
          ? String.fromCodePoint(code) : raw;
      }) : token.text;
      pushTextNode(out, text, mention ? [...activeMarks, mention] : activeMarks);
      continue;
    }
    if (token.type === 'br') {
      out.push({ type: 'hardBreak' });
      continue;
    }
    if (token.type === 'image') {
      out.push({
        type: 'fdStorageImage',
        attrs: {
          src: token.href,
          alt: token.text || null,
          title: token.title || null,
          objectId: String(token.href || '').startsWith('storage://') ? String(token.href).slice('storage://'.length) : null,
        },
      });
      continue;
    }
    if (token.type === 'link') {
      const mentionParts = mentionPartsFromHref(token.href);
      if (mentionParts && consumeMentionMarker(out)) {
        const label = textFromInlineToken(token) || token.text || mentionParts.mentionId;
        pushTextNode(out, label, [
          ...activeMarks,
          {
            type: 'fdMention',
            attrs: {
              label,
              mentionType: mentionParts.mentionType,
              mentionId: mentionParts.mentionId,
            },
          },
        ]);
        continue;
      }
    }
    const nextMarks = [...activeMarks, ...marksForToken(token)];
    if (Array.isArray(token.tokens)) {
      out.push(...inlineContent(token.tokens, nextMarks));
    } else {
      pushTextNode(out, token.text || token.raw || '', nextMarks);
    }
  }
  return out;
}

function listItemContentFromToken(token = {}) {
  if (!token || token.type === 'space' || token.type === 'checkbox') return null;
  if (token.type === 'text' || token.type === 'paragraph') {
    const inlineTokens = Array.isArray(token.tokens) ? token.tokens : [token];
    const inline = inlineContent(inlineTokens.filter((child) => child?.type !== 'checkbox'));
    return inline.length > 0 ? { type: 'paragraph', content: inline } : paragraphFromText(token.text || '');
  }
  return nodeFromToken(token);
}

function listItemFromToken(item = {}, taskList = false) {
  const attrs = taskList ? { checked: item.checked === true } : {};
  const children = (item.tokens || []).map(listItemContentFromToken).filter(Boolean);
  if (children.length === 0 || children[0]?.type !== 'paragraph') {
    // A nested block can follow an empty parent item. Its raw Markdown is
    // already represented by children; copying item.text duplicates it.
    children.unshift(paragraphFromText(children.length ? '' : item.text || ''));
  }
  return { type: taskList ? 'taskItem' : 'listItem', attrs, content: children };
}

function tableFromToken(token = {}, attrs = {}) {
  const rows = [];
  const headerCells = (token.header || []).map((cell) => ({
    type: 'tableHeader',
    content: [{ type: 'paragraph', content: inlineContent(cell.tokens || [{ type: 'text', text: cell.text || '' }]) }],
  }));
  if (headerCells.length > 0) rows.push({ type: 'tableRow', content: headerCells });
  for (const row of token.rows || []) {
    rows.push({
      type: 'tableRow',
      content: row.map((cell) => ({
        type: 'tableCell',
        content: [{ type: 'paragraph', content: inlineContent(cell.tokens || [{ type: 'text', text: cell.text || '' }]) }],
      })),
    });
  }
  return { type: 'table', attrs, content: rows };
}

function nodeFromToken(token = {}, attrs = {}) {
  // Marked treats a paragraph beginning with an inline HTML tag as an HTML
  // block. Interpret only the tags emitted by our rich serializer, never HTML
  // through a DOM or a general HTML importer.
  if (token.type === 'html' && /^(?:<br\s*\/?\s*>|<u>)/i.test(token.raw)) {
    return { type: 'paragraph', attrs, content: inlineContent(marked.Lexer.lexInline(token.raw.trimEnd())) };
  }
  if (token.type === 'heading') {
    return { type: 'heading', attrs: { ...attrs, level: token.depth || 1 }, content: inlineContent(token.tokens || []) };
  }
  if (token.type === 'paragraph') {
    const inline = inlineContent(token.tokens || []);
    return inline.length > 0 ? { type: 'paragraph', attrs, content: inline } : paragraphFromText(token.text || '', attrs);
  }
  if (token.type === 'code') {
    return {
      type: 'codeBlock',
      attrs: { ...attrs, language: token.lang || null },
      content: token.text ? [{ type: 'text', text: token.text }] : [],
    };
  }
  if (token.type === 'blockquote') {
    return {
      type: 'blockquote',
      attrs,
      content: tokensToProseMirrorNodes(token.tokens || [], []),
    };
  }
  if (token.type === 'hr') {
    return { type: 'horizontalRule', attrs };
  }
  if (token.type === 'list') {
    const taskList = (token.items || []).some((item) => item.task);
    return {
      type: taskList ? 'taskList' : (token.ordered ? 'orderedList' : 'bulletList'),
      attrs: token.ordered ? { ...attrs, start: token.start || 1 } : attrs,
      content: (token.items || []).map((item) => listItemFromToken(item, taskList)),
    };
  }
  if (token.type === 'table') return tableFromToken(token, attrs);
  if (token.type === 'space') return null;
  return paragraphFromText(token.raw || token.text || '', attrs);
}

function tokensToProseMirrorNodes(tokens = [], contentBlocks = []) {
  const normalizedBlocks = normalizeDocumentBlocks(contentBlocks);
  let blockIndex = 0;
  return (tokens || [])
    .map((token) => {
      if (token?.type === 'space') return null;
      const block = normalizedBlocks[blockIndex] || null;
      blockIndex += 1;
      const attrs = { fdBlockId: String(block?.id || '').trim() || createFlightDeckBlockId() };
      return nodeFromToken(token, attrs);
    })
    .filter(Boolean);
}

export function markdownToProseMirrorDoc(content = '', options = {}) {
  const source = String(content || '');
  const tokens = marked.lexer(source);
  const nodes = tokensToProseMirrorNodes(tokens, options.contentBlocks || []);
  return {
    type: 'doc',
    content: nodes.length > 0 ? nodes : [{ type: 'paragraph', attrs: { fdBlockId: createFlightDeckBlockId() } }],
  };
}

export function resolveDocumentProseMirrorState(document = {}) {
  const state = document?.editor_state && typeof document.editor_state === 'object' && !Array.isArray(document.editor_state)
    ? document.editor_state
    : null;
  if (state?.type === 'doc') return state;
  return markdownToProseMirrorDoc(document?.content || '', { contentBlocks: document?.content_blocks || [] });
}
