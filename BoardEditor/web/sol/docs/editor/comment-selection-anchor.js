import { prosemirrorToFlightDeckContentModel } from './prosemirror-to-flightdeck.js';

function rawEditor(editor) {
  const alpine = typeof globalThis !== 'undefined' ? globalThis.Alpine : null;
  return typeof alpine?.raw === 'function' ? alpine.raw(editor) : editor;
}

function selectedText(doc, from, to) {
  if (!doc || !Number.isFinite(from) || !Number.isFinite(to) || to <= from) return '';
  try {
    return doc.textBetween(from, to, '\n', '');
  } catch {
    return '';
  }
}

function blockMarkdown(node) {
  if (!node?.toJSON) return '';
  return prosemirrorToFlightDeckContentModel({
    type: 'doc',
    content: [node.toJSON()],
  }).content || '';
}

export function richEditorLineAtPosition(doc, position) {
  if (!doc?.forEach) return 1;
  const target = Math.max(0, Number(position) || 0);
  const parts = [];
  let finished = false;

  doc.forEach((node, offset) => {
    if (finished) return;
    const contentStart = offset + 1;
    const contentEnd = contentStart + Number(node?.content?.size || 0);
    if (target >= contentEnd) {
      const markdown = blockMarkdown(node);
      if (markdown.trim()) parts.push(markdown);
      return;
    }
    if (target <= contentStart) {
      parts.push('');
      finished = true;
      return;
    }
    const relativePosition = Math.max(0, Math.min(target - contentStart, Number(node?.content?.size || 0)));
    const prefix = typeof node.cut === 'function' ? node.cut(0, relativePosition) : node;
    parts.push(blockMarkdown(prefix));
    finished = true;
  });

  const markdownPrefix = parts.join('\n\n');
  return 1 + (markdownPrefix.match(/\n/g) || []).length;
}

export function captureRichEditorSelectionAnchor(editor) {
  const activeEditor = rawEditor(editor);
  const selection = activeEditor?.state?.selection;
  const doc = activeEditor?.state?.doc;
  if (!selection || !doc) return null;
  const from = Math.min(Number(selection.from), Number(selection.to));
  const to = Math.max(Number(selection.from), Number(selection.to));
  if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) return null;
  const quote = selectedText(doc, from, to);
  if (!quote || !quote.trim()) return null;
  return {
    anchor_quote: quote,
    anchor_line_number: richEditorLineAtPosition(doc, from),
    anchor_end_line_number: richEditorLineAtPosition(doc, Math.max(from, to - 1)),
    anchor_start_offset: from,
    anchor_end_offset: to,
  };
}

function normalizeStoredAnchor(comment = {}) {
  const metadata = comment?.pg_metadata && typeof comment.pg_metadata === 'object'
    ? comment.pg_metadata
    : {};
  const quote = String(comment.anchor_quote ?? metadata.anchor_quote ?? '');
  const from = Number(comment.anchor_start_offset ?? metadata.anchor_start_offset);
  const to = Number(comment.anchor_end_offset ?? metadata.anchor_end_offset);
  return { quote, from, to };
}

export function resolveRichEditorSelectionAnchor(editor, comment = {}) {
  const activeEditor = rawEditor(editor);
  const doc = activeEditor?.state?.doc;
  const anchor = normalizeStoredAnchor(comment);
  if (!doc || !anchor.quote) return { state: 'unavailable', reason: 'missing-editor-or-quote' };

  if (
    Number.isFinite(anchor.from)
    && Number.isFinite(anchor.to)
    && anchor.to > anchor.from
    && selectedText(doc, anchor.from, anchor.to) === anchor.quote
  ) {
    return { state: 'found', from: anchor.from, to: anchor.to, relocated: false };
  }

  const span = anchor.to - anchor.from;
  if (!Number.isFinite(span) || span <= 0) return { state: 'stale', reason: 'missing-offsets' };
  const maxPosition = Number(doc?.content?.size || 0);
  const matches = [];
  for (let from = 0; from + span <= maxPosition; from += 1) {
    const to = from + span;
    if (selectedText(doc, from, to) !== anchor.quote) continue;
    matches.push({ from, to });
    if (matches.length > 1) break;
  }
  if (matches.length === 1) return { state: 'found', ...matches[0], relocated: true };
  return {
    state: 'stale',
    reason: matches.length > 1 ? 'ambiguous-quote' : 'quote-not-found',
  };
}

export function revealRichEditorSelectionAnchor(editor, comment = {}) {
  const activeEditor = rawEditor(editor);
  const resolved = resolveRichEditorSelectionAnchor(activeEditor, comment);
  if (resolved.state !== 'found') return resolved;
  const range = { from: resolved.from, to: resolved.to };
  if (activeEditor?.chain) activeEditor.chain().focus().setTextSelection(range).run();
  else activeEditor?.commands?.setTextSelection?.(range);
  return resolved;
}
