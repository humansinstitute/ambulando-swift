import { markdownToProseMirrorDoc } from './editor/markdown-to-prosemirror.js';

// Channel-local lookup uses only materialized, readable rows. IDs never fall back
// to title lookup: a deleted target must not silently become a different page.
export function channelWikiPages(documents = [], channelId = '') {
  if (!channelId) return [];
  return documents.filter((doc) => doc.pg_channel_id === channelId
    && !['deleted', 'archived'].includes(doc.record_state)
    && !doc.deleted_at && !doc.archived_at);
}

export function resolveWikiPage(documents, channelId, { documentId, title } = {}) {
  const pages = channelWikiPages(documents, channelId);
  const matches = documentId ? pages.filter((doc) => doc.record_id === documentId)
    : pages.filter((doc) => String(doc.title || '').trim().toLocaleLowerCase() === String(title || '').trim().toLocaleLowerCase());
  if (matches.length === 1) return { state: 'available', page: matches[0], title: matches[0].title };
  return { state: matches.length > 1 ? 'ambiguous' : documentId ? 'unavailable' : 'unresolved', title };
}

export function wikiSource({ documentId, title }) {
  const label = String(title || 'Untitled document');
  return documentId ? `[${label.replace(/([\\`*_{}\[\]()#+\-.!|>&])/g, '\\$1')}](wiki:${encodeURIComponent(documentId)})`
    : `[[${label}]]`;
}

export function bindWikiState(state, documents, channelId) {
  const visit = (node) => {
    if (!node) return node;
    if (node.type === 'fdWikiLink' && !node.attrs?.documentId) {
      const resolved = resolveWikiPage(documents, channelId, node.attrs);
      if (resolved.page) return { ...node, attrs: { ...node.attrs, documentId: resolved.page.record_id } };
    }
    if (!node.content) return node;
    const content = node.content.map(visit);
    return content.some((child, index) => child !== node.content[index]) ? { ...node, content } : node;
  };
  return visit(state);
}

// Cache parsing per immutable materialized row; selection/title resolution stays live.
const referencesByRow = new WeakMap();
function pageReferences(page) {
  const signature = [page.editor_state, page.content, page.content_blocks];
  const cached = referencesByRow.get(page);
  if (cached && signature.every((value, index) => value === cached.signature[index])) return cached.links;
  const links = [];
  const visit = (node) => {
    if (node?.type === 'fdWikiLink') links.push(node.attrs || {});
    for (const child of node?.content || []) visit(child);
  };
  visit(page.editor_state || markdownToProseMirrorDoc(page.content || (page.content_blocks || []).map(block => block.raw || '').join('\n\n')));
  referencesByRow.set(page, { signature, links });
  return links;
}
export function incomingWikiPages(documents, target) {
  if (!target?.record_id || !target.pg_channel_id) return [];
  const pages = channelWikiPages(documents, target.pg_channel_id);
  if (!pages.some(page => page.record_id === target.record_id)) return [];
  const title = String(target.title || '').trim().toLocaleLowerCase();
  const uniqueTitle = pages.filter(page => String(page.title || '').trim().toLocaleLowerCase() === title).length === 1;
  return pages.filter(page => page.record_id !== target.record_id && pageReferences(page).some(attrs =>
    attrs.documentId ? attrs.documentId === target.record_id
      : uniqueTitle && String(attrs.title || '').trim().toLocaleLowerCase() === title))
    .filter((page, index, all) => all.findIndex(other => other.record_id === page.record_id) === index)
    .sort((a, b) => String(a.title || '').localeCompare(String(b.title || '')));
}
