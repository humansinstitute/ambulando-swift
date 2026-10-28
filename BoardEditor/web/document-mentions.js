// Native supplies authorized local suggestions; this page only edits links and reports activation.
import { Extension } from '@tiptap/core';
import { Plugin } from '@tiptap/pm/state';

export function mentionRange(state) {
  const { $from, empty } = state.selection;
  if (!empty || !$from.parent.isTextblock || $from.parent.type.spec.code) return null;
  if ($from.marks().some(m => ['code', 'fdMention', 'link'].includes(m.type.name))) return null;
  const before = $from.parent.textBetween(0, $from.parentOffset, '\ufffc');
  const match = before.match(/(?:^|\s)@([^@\n]{0,80})$/);
  return match ? { from: $from.pos - match[1].length - 1, to: $from.pos, query: match[1] } : null;
}

export function insertMention(editor, candidate, range) {
  const current = mentionRange(editor.state);
  if (!current || current.from !== range.from || current.to !== range.to || current.query !== range.query) return false;
  const mark = candidate.url ? editor.schema.marks.link.create({ href: candidate.url })
    : editor.schema.marks.fdMention.create({ label: candidate.label, mentionType: candidate.type, mentionId: candidate.id });
  const marks = editor.state.selection.$from.marks().filter(m => !['link', 'fdMention'].includes(m.type.name));
  const node = editor.schema.text(candidate.label, [...marks, mark]);
  editor.view.dispatch(editor.state.tr.replaceWith(range.from, range.to, [node, editor.schema.text(' ', marks)]).removeStoredMark(mark.type).scrollIntoView());
  editor.view.focus();
  return true;
}

export function recordLinkClickAllowed(start, event) {
  if (event.shiftKey || event.button !== 0) return false;
  if (!start) return event.detail === 0;
  return !start.cancelled && Math.hypot(event.clientX - start.x, event.clientY - start.y) <= 5;
}

export function documentMentions({ post, changed }) {
  let active = null, last = '', rows = [], selected = 0, popup = null, editor = null, dismissed = '', gesture = null;
  const close = () => { popup?.remove(); popup = null; rows = []; };
  const pick = row => { if (editor && active && insertMention(editor, row, active)) changed(); close(); };
  const render = () => {
    popup?.remove(); popup = null;
    if (!rows.length || !active || !editor) return;
    popup = document.createElement('div'); popup.className = 'document-mention-picker'; popup.setAttribute('role', 'listbox'); popup.setAttribute('aria-label', 'Link to a record');
    rows.forEach((row, i) => {
      const button = document.createElement('button'); button.type = 'button'; button.setAttribute('role', 'option'); button.setAttribute('aria-selected', String(i === selected));
      button.textContent = `${row.label} · ${row.detail}`;
      button.addEventListener('mousedown', e => e.preventDefault()); button.addEventListener('click', () => pick(row)); popup.append(button);
    });
    document.body.append(popup);
    popup.children[selected]?.scrollIntoView({ block: 'nearest' });
  };
  return {
    deliver(request) {
      if (!active || !request.range || active.from !== request.range.from || active.to !== request.range.to || active.query !== request.range.query) return false;
      rows = request.rows || []; selected = 0; render(); return true;
    },
    extension: Extension.create({
      name: 'nativeDocumentMentions',
      onCreate() { editor = this.editor; },
      addProseMirrorPlugins() { return [new Plugin({
        props: {
          handleDOMEvents: {
            pointerdown(view, event) {
              const target = event.target.closest?.('[data-mention-id], a[href]');
              gesture = target ? { target, x: event.clientX, y: event.clientY, cancelled: event.shiftKey || event.button !== 0 } : null;
              return false;
            },
            pointermove(view, event) {
              if (gesture && (event.shiftKey || Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y) > 5)) gesture.cancelled = true;
              return false;
            },
            pointercancel() { gesture = null; return false; },
            click(view, event) {
              const target = event.target.closest?.('[data-mention-id], a[href]');
              const start = gesture; gesture = null;
              if (!target || (start && start.target !== target) || !recordLinkClickAllowed(start, event)) return false;
              const type = target.dataset.mentionType, id = target.dataset.mentionId;
              const url = target.getAttribute('href');
              if (!id && (!url || url === '#')) return false;
              event.preventDefault(); post({ type: 'record-link', kind: type, id, url }); return true;
            },
          },
          handleKeyDown(view, event) {
            const focused = event.target.closest?.('[data-mention-id]');
            if (event.key === 'Enter' && focused) {
              event.preventDefault(); post({ type: 'record-link', kind: focused.dataset.mentionType, id: focused.dataset.mentionId }); return true;
            }
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              const mark = view.state.selection.$from.marks().find(m => ['fdMention', 'link'].includes(m.type.name));
              if (mark) { event.preventDefault(); post({ type: 'record-link', kind: mark.attrs.mentionType, id: mark.attrs.mentionId, url: mark.attrs.href }); return true; }
            }
            if (!rows.length || !active) return false;
            if (event.key === 'Escape') { dismissed = last; close(); event.preventDefault(); return true; }
            if (['ArrowDown', 'ArrowUp'].includes(event.key)) { selected = (selected + (event.key === 'ArrowDown' ? 1 : rows.length - 1)) % rows.length; render(); event.preventDefault(); return true; }
            if (['Enter', 'Tab'].includes(event.key)) { event.preventDefault(); pick(rows[selected]); return true; }
            return false;
          },
        },
        view: () => ({ update(view) {
          active = mentionRange(view.state);
          const next = active ? JSON.stringify(active) : '';
          if (next === last) return;
          last = next; close();
          if (next !== dismissed) post({ type: 'mention-query', range: active });
        }, destroy() { close(); editor = null; } }),
      })]; },
    }),
  };
}
