// Rich coordinates use sol's helper; Markdown coordinates refer to saved source lines.
import { captureRichEditorSelectionAnchor, revealRichEditorSelectionAnchor } from './sol/docs/editor/comment-selection-anchor.js';
import { markdownSource } from './document-preserve.js';
function text(node) {
  if (node.type === 'text') return node.text || '';
  if (node.type === 'hardBreak') return '\n';
  return (node.content || []).map(text).join('');
}
export function captureSelection(editor, markdown = null) {
  const anchor = captureRichEditorSelectionAnchor(editor);
  if (!anchor || markdown === null) return anchor;
  const parsed = markdownSource(markdown);
  if (!parsed.blocks) return null;
  let index = -1;
  editor.state.doc.forEach((node, offset, i) => {
    if (anchor.anchor_start_offset >= offset + 1 && anchor.anchor_end_offset <= offset + node.nodeSize - 1) index = i;
  });
  if (index < 0 || !parsed.blocks[index]) return null;
  let start = parsed.lead.length;
  for (let i = 0; i < index; i++) start += parsed.blocks[i].body.length + parsed.blocks[i].after.length;
  const firstLine = 1 + (markdown.slice(0, start).match(/\n/g) || []).length;
  const matches = parsed.blocks[index].body.split('\n').flatMap((line, i) => {
    const rendered = text(markdownSource(line).doc);
    return rendered.includes(anchor.anchor_quote) ? [firstLine + i] : [];
  });
  if (matches.length !== 1) return null;
  return { anchor_quote: anchor.anchor_quote, anchor_line_number: matches[0] };
}
export function revealSelection(editor, anchor, markdown = null) {
  if (markdown === null || Number.isFinite(anchor.anchor_start_offset)) return revealRichEditorSelectionAnchor(editor, anchor);
  const parsed = markdownSource(markdown);
  if (!parsed.blocks) return { state: 'unavailable' };
  let line = 1 + (parsed.lead.match(/\n/g) || []).length;
  let found = null;
  editor.state.doc.forEach((node, offset, i) => {
    const block = parsed.blocks[i];
    if (!block) return;
    const end = line + (block.body.match(/\n/g) || []).length;
    if (anchor.anchor_line_number >= line && anchor.anchor_line_number <= end) {
      const quote = anchor.anchor_quote, content = node.textContent, index = content.indexOf(quote);
      if (index >= 0 && content.indexOf(quote, index + 1) < 0) {
        found = revealRichEditorSelectionAnchor(editor, { ...anchor, anchor_start_offset: offset + 1 + index, anchor_end_offset: offset + 1 + index + quote.length });
      }
    }
    line = end + (block.after.match(/\n/g) || []).length;
  });
  return found || { state: 'unavailable' };
}
