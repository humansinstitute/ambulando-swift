/**
 * Pure data-transform and comparison helpers extracted from app.js.
 */

/** Strip Alpine proxy wrappers so objects survive IndexedDB structured clone. */
export function toRaw(obj) {
  if (obj == null || typeof obj !== 'object') return obj;
  return JSON.parse(JSON.stringify(obj));
}

export function isFipsUrl(value) {
  try { return new URL(String(value || '').trim()).hostname.endsWith('.fips'); }
  catch { return false; }
}

export function normalizeBackendUrl(url) {
  if (!url) return '';

  try {
    const parsed = new URL(url);

    if (typeof window === 'undefined') return parsed.toString().replace(/\/+$/, '');

    const current = new URL(window.location.origin);

    const localAppShell = ['127.0.0.1', 'localhost', '::1'].includes(current.hostname);
    const remoteBackend = !['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname);
    if (
      parsed.protocol === 'http:'
      && !parsed.hostname.endsWith('.fips')
      && (current.protocol === 'https:' || (localAppShell && remoteBackend))
    ) {
      parsed.protocol = 'https:';
    }

    if (
      !localAppShell
      &&
      parsed.hostname === current.hostname
      && parsed.pathname === '/'
      && parsed.port === '3100'
    ) {
      return current.origin;
    }

    return parsed.toString().replace(/\/+$/, '');
  } catch {
    return String(url).trim().replace(/\/+$/, '');
  }
}

export function workspaceSettingsRecordId(workspaceOwnerNpub) {
  return `workspace-settings:${workspaceOwnerNpub}`;
}

export function storageObjectIdFromRef(value) {
  const match = String(value || '').trim().match(/^storage:\/\/([A-Za-z0-9-]+)$/);
  return match?.[1] || '';
}

export function storageImageCacheKey(objectId, backendUrl = '') {
  const normalizedObjectId = String(objectId || '').trim();
  const normalizedBackendUrl = String(backendUrl || '').trim().replace(/\/+$/, '');
  if (!normalizedObjectId) return '';
  return normalizedBackendUrl ? `${normalizedBackendUrl}::${normalizedObjectId}` : normalizedObjectId;
}

export function defaultRecordSignature(record) {
  return [
    String(record?.record_id || ''),
    String(record?.updated_at || ''),
    String(record?.version ?? ''),
    String(record?.record_state || ''),
    String(record?.sync_status || ''),
  ].join('|');
}

export function sameListBySignature(current = [], next = [], signatureFor = defaultRecordSignature) {
  if (current === next) return true;
  if (!Array.isArray(current) || !Array.isArray(next) || current.length !== next.length) return false;
  for (let index = 0; index < current.length; index += 1) {
    if (signatureFor(current[index]) !== signatureFor(next[index])) return false;
  }
  return true;
}

export function stableValueSignature(value) {
  if (value == null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableValueSignature).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableValueSignature(value[key])}`).join(',')}}`;
}

export function sameLogicalValue(current, next) {
  if (current === next) return true;
  return stableValueSignature(current) === stableValueSignature(next);
}

const BLOCK_DOCUMENT_FORMAT = 'block_document_v1';

function makeBlockId(index, startLine) {
  return `block-${index}-${startLine}`;
}

function blockText(block) {
  return String(block?.raw ?? block?.text ?? '').trimEnd();
}

function isStandaloneMarkdownImageLine(line) {
  return /^\\?!\[[^\]\n]*]\([^)]+\)\s*$/.test(String(line || '').trim());
}

function isStandaloneMarkdownHeadingLine(line) {
  return /^#{1,6}\s+\S.*$/.test(String(line || '').trim());
}

function splitMarkdownIntoBlockSegments(content) {
  const source = String(content || '').replace(/\r\n?/g, '\n');
  if (!source.trim()) return [];

  const lines = source.split('\n');
  const segments = [];
  let currentLines = [];
  let startLine = 1;

  const flush = () => {
    if (currentLines.length === 0) return;
    const raw = currentLines.join('\n').trimEnd();
    if (raw) {
      segments.push({
        raw,
        startLine,
        lineCount: currentLines.length,
      });
    }
    currentLines = [];
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? '';
    const lineNumber = index + 1;

    if (!line.trim()) {
      flush();
      startLine = lineNumber + 1;
      continue;
    }

    if (isStandaloneMarkdownImageLine(line) || isStandaloneMarkdownHeadingLine(line)) {
      flush();
      segments.push({
        raw: line.trimEnd(),
        startLine: lineNumber,
        lineCount: 1,
      });
      startLine = lineNumber + 1;
      continue;
    }

    if (currentLines.length === 0) startLine = lineNumber;
    currentLines.push(line);
  }

  flush();
  return segments;
}

export function normalizeDocumentBlocks(blocks = [], fallbackContent = '') {
  const sourceBlocks = Array.isArray(blocks) ? blocks : [];
  if (sourceBlocks.length === 0 && String(fallbackContent || '').trim()) {
    return parseMarkdownBlocks(fallbackContent);
  }

  let line = 1;
  const normalizedBlocks = [];
  const usedIds = new Set();
  const uniqueBlockId = (candidate, fallbackIndex, fallbackLine) => {
    const fallback = makeBlockId(fallbackIndex, fallbackLine);
    const base = String(candidate || '').trim() || fallback;
    let next = base;
    let suffix = 2;
    while (usedIds.has(next)) {
      next = `${base}-${suffix}`;
      suffix += 1;
    }
    usedIds.add(next);
    return next;
  };

  sourceBlocks.forEach((block) => {
    const raw = blockText(block);
    if (!raw) return;
    const segments = splitMarkdownIntoBlockSegments(raw);
    segments.forEach((segment, segmentIndex) => {
      const blockIndex = normalizedBlocks.length;
      const sourceId = String(block?.id || '').trim() || makeBlockId(blockIndex, line);
      normalizedBlocks.push({
        id: uniqueBlockId(
          segmentIndex === 0 ? sourceId : `${sourceId}:split-${segmentIndex}`,
          blockIndex,
          line,
        ),
        type: String(block?.type || '').trim() || 'markdown',
        raw: segment.raw,
        text: segment.raw,
        attrs: block?.attrs && typeof block.attrs === 'object' && !Array.isArray(block.attrs)
          ? { ...block.attrs }
          : {},
        start_line: line,
        end_line: line + segment.lineCount - 1,
      });
      line += segment.lineCount + 1;
    });
  });
  if (normalizedBlocks.length === 0 && String(fallbackContent || '').trim()) {
    return parseMarkdownBlocks(fallbackContent);
  }
  return normalizedBlocks;
}

export function createDocumentBlock(raw = '', options = {}) {
  const text = String(raw || '').trimEnd();
  const id = String(options.id || '').trim()
    || (globalThis.crypto?.randomUUID ? `blk_${globalThis.crypto.randomUUID()}` : `blk_${Date.now()}_${Math.random().toString(36).slice(2)}`);
  return {
    id,
    type: String(options.type || '').trim() || 'markdown',
    raw: text,
    text,
    attrs: options.attrs && typeof options.attrs === 'object' && !Array.isArray(options.attrs)
      ? { ...options.attrs }
      : {},
  };
}

export function serializeDocumentBlocks(blocks = []) {
  return normalizeDocumentBlocks(blocks).map((block) => ({
    id: block.id,
    type: block.type || 'markdown',
    text: blockText(block),
    attrs: block.attrs && typeof block.attrs === 'object' && !Array.isArray(block.attrs)
      ? { ...block.attrs }
      : {},
  }));
}

export function documentBlocksToMarkdown(blocks = []) {
  return normalizeDocumentBlocks(blocks)
    .map((block) => blockText(block))
    .filter((raw) => raw.length > 0)
    .join('\n\n');
}

export function parseMarkdownBlocks(content, options = {}) {
  const segments = splitMarkdownIntoBlockSegments(content);
  if (segments.length === 0) return [];
  const previousBlocks = Array.isArray(options?.previousBlocks) ? options.previousBlocks : [];

  return segments.map((segment, index) => {
    const previous = previousBlocks[index] || null;
    return {
      id: String(previous?.id || '').trim() || makeBlockId(index, segment.startLine),
      type: String(previous?.type || '').trim() || 'markdown',
      raw: segment.raw,
      text: segment.raw,
      attrs: previous?.attrs && typeof previous.attrs === 'object' && !Array.isArray(previous.attrs)
        ? { ...previous.attrs }
        : {},
      start_line: segment.startLine,
      end_line: segment.startLine + segment.lineCount - 1,
    };
  });
}

export function assembleMarkdownBlocks(blocks = []) {
  return documentBlocksToMarkdown(blocks);
}

export function buildDocumentContentModel(blocks = []) {
  const normalizedBlocks = normalizeDocumentBlocks(blocks);
  return {
    content: documentBlocksToMarkdown(normalizedBlocks),
    content_format: BLOCK_DOCUMENT_FORMAT,
    content_blocks: serializeDocumentBlocks(normalizedBlocks),
  };
}

export { BLOCK_DOCUMENT_FORMAT };
