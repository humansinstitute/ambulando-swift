import { Node, Extension } from '@tiptap/core';
import { Plugin } from '@tiptap/pm/state';

export const FlightDeckWikiLink = Node.create({
  name: 'fdWikiLink', inline: true, group: 'inline', atom: true,
  addAttributes() { return { documentId: { default: null }, title: { default: '' } }; },
  parseHTML() { return [{ tag: 'span[data-wiki-title]', getAttrs: (el) => ({ documentId: el.dataset.wikiId || null, title: el.dataset.wikiTitle }) }]; },
  renderHTML({ node }) { return ['span', { class: 'fd-wiki-link', 'data-wiki-id': node.attrs.documentId, 'data-wiki-title': node.attrs.title }, node.attrs.title]; },
  renderText({ node }) { return node.attrs.title; },
  addNodeView() {
    return ({ node, getPos, editor }) => {
      const dom = document.createElement('span');
      dom.contentEditable = 'false';
      dom.setAttribute('role', 'link');
      dom.tabIndex = 0;
      let current = node;
      const refresh = () => {
        const resolved = this.options.resolve(current.attrs);
        dom.setAttribute('aria-disabled', String(this.options.isBusy()));
        dom.className = `fd-wiki-link fd-wiki-${resolved.state}`;
        dom.dataset.wikiTitle = current.attrs.title;
        dom.dataset.wikiId = current.attrs.documentId || resolved.page?.record_id || '';
        // Focus/selection transactions run between mouse-down and click. Keep the
        // native hit target stable when its label has not changed.
        const title = resolved.title || current.attrs.title;
        if (dom.textContent !== title) dom.textContent = title;
        dom.title = resolved.state === 'available' ? 'Open page'
          : resolved.state === 'unresolved' ? 'Page does not exist. Click to create.'
          : resolved.state === 'ambiguous' ? 'Several pages have this title. Use the [[ picker to choose one.' : 'Page deleted or unavailable';
        dom.setAttribute('aria-label', `${dom.textContent}: ${resolved.state}`);
      };
      let pointerOrigin = null;
      let dragged = false;
      const pointerSurface = dom.ownerDocument;
      const stopTracking = () => {
        pointerSurface.removeEventListener('pointermove', trackDrag);
        pointerSurface.removeEventListener('pointerup', stopTracking);
        pointerSurface.removeEventListener('pointercancel', cancelPointer);
      };
      const trackDrag = (event) => {
        if (pointerOrigin && Math.hypot(event.clientX - pointerOrigin.x, event.clientY - pointerOrigin.y) > 5) dragged = true;
      };
      const cancelPointer = () => { dragged = true; stopTracking(); };
      dom.addEventListener('pointerdown', (event) => {
        pointerOrigin = { x: event.clientX, y: event.clientY }; dragged = false;
        pointerSurface.addEventListener('pointermove', trackDrag);
        pointerSurface.addEventListener('pointerup', stopTracking);
        pointerSurface.addEventListener('pointercancel', cancelPointer);
      });
      dom.addEventListener('mousedown', (event) => {
        if (event.button !== 0 || !event.shiftKey) return;
        // A focusable atom steals WebKit's native text selection. Extend the
        // editor selection from its existing anchor instead of focusing the link.
        event.preventDefault(); event.stopPropagation();
        const anchor = editor.state.selection.anchor;
        const pos = getPos();
        editor.commands.setTextSelection({ from: anchor, to: pos < anchor ? pos : pos + current.nodeSize });
        editor.view.focus();
      });
      const activate = (event) => {
        // Follow ordinary clicks/taps, but never turn a selection drag into navigation.
        if (event.type === 'click' && (event.button !== 0 || event.shiftKey || dragged
          || (pointerOrigin && Math.hypot(event.clientX - pointerOrigin.x, event.clientY - pointerOrigin.y) > 5))) return;
        event.preventDefault(); event.stopPropagation();
        if (this.options.isBusy()) return;
        const resolved = this.options.resolve(current.attrs);
        if (current.attrs.documentId || resolved.state === 'available') this.options.open(current.attrs.documentId || resolved.page.record_id);
        else if (resolved.state === 'unresolved') this.options.create(current.attrs.title, { from: getPos(), to: getPos() + current.nodeSize }, editor);
        else this.options.error(dom.title);
      };
      dom.addEventListener('click', activate);
      dom.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') activate(event); });
      editor.on('transaction', refresh);
      refresh();
      return { dom,
        // The link owns activation. ProseMirror's atom mouse-down handler can
        // select/refocus it before click, swallowing the first native activation.
        // Leave Shift selection, keyboard movement and native drags available.
        stopEvent: (event) => event.type === 'mousedown' && event.button === 0 && !event.shiftKey,
        ignoreMutation: () => true, update(next) { if (next.type !== node.type) return false; current = next; refresh(); return true; }, destroy() { editor.off('transaction', refresh); stopTracking(); } };
    };
  },
  addOptions() { return { resolve: () => ({ state: 'unavailable' }), open: () => {}, create: () => {}, error: () => {}, isBusy: () => false, isEditing: () => false }; },
});

export function wikiPickerRange(state) {
  const { $from, empty } = state.selection;
  if (!empty || !$from.parent.isTextblock || $from.parent.type.name === 'codeBlock') return null;
  const before = $from.parent.textBetween(0, $from.parentOffset, '', '\ufffc');
  const match = /\[\[([^\]\n]*)$/.exec(before);
  if (!match) return null;
  return { from: $from.pos - match[0].length, to: $from.pos, query: match[1] };
}

export function createWikiPicker({ pages, resolve, create, error, isEditing, isBusy = () => false }) {
  return Extension.create({
    name: 'fdWikiPicker',
    addProseMirrorPlugins() {
      let picker = null;
      return [new Plugin({
        appendTransaction(transactions, _old, state) {
          if (!this.spec.editable?.() || !transactions.some((tr) => tr.docChanged || tr.getMeta('wikiRefresh'))) return null;
          const replacements = [];
          state.doc.descendants((node, pos, parent) => {
            if (parent?.type.name === 'codeBlock') return false;
            if (node.type.name === 'fdWikiLink' && !node.attrs.documentId) {
              const found = resolve(node.attrs);
              if (found.state === 'available') replacements.push({ from: pos, to: pos + node.nodeSize, attrs: { ...node.attrs, documentId: found.page.record_id } });
            }
            if (!node.isText || node.marks.some((mark) => ['code', 'link', 'fdMention'].includes(mark.type.name))) return;
            for (const match of node.text.matchAll(/\[\[([^\]\n]+)\]\]/g)) {
              const found = resolve({ title: match[1] });
              replacements.push({ from: pos + match.index, to: pos + match.index + match[0].length, attrs: { title: match[1], documentId: found.page?.record_id || null } });
            }
          });
          if (!replacements.length) return null;
          const tr = state.tr;
          for (const replacement of replacements.reverse()) tr.replaceWith(replacement.from, replacement.to, state.schema.nodes.fdWikiLink.create(replacement.attrs));
          return tr;
        },
        editable: () => this.editor.isEditable && isEditing(),
        props: { handleKeyDown(_view, event) { return picker?.keydown(event) || false; } },
        view: (view) => {
          const el = document.createElement('div');
          el.className = 'fd-wiki-picker'; el.setAttribute('role', 'listbox'); el.setAttribute('aria-label', 'Link to a channel page');
          document.body.append(el);
          let range = null, choices = [], active = 0, signature = '', dismissed = '', pending = false;
          const choose = async (index) => {
            if (!range || pending || isBusy()) return;
            pending = true;
            for (const button of el.querySelectorAll('button')) button.disabled = true;
            const selectedRange = { ...range }, choice = choices[index];
            try {
              if (choice?.record_id) {
                view.dispatch(view.state.tr.replaceWith(selectedRange.from, selectedRange.to, view.state.schema.nodes.fdWikiLink.create({ documentId: choice.record_id, title: choice.title })));
                view.focus();
              } else if (selectedRange.query.trim()) await create(selectedRange.query.trim(), selectedRange, this.editor);
            } catch (cause) { error(cause.message || 'Could not link page.'); }
            finally { pending = false; dismissed = signature; el.hidden = true; }
          };
          const render = () => {
            range = this.editor.isEditable ? wikiPickerRange(view.state) : null;
            const next = range ? `${range.from}:${range.query}` : '';
            if (next !== signature) active = 0;
            signature = next;
            el.hidden = !range || signature === dismissed;
            if (el.hidden) return;
            choices = pages().filter((page) => String(page.title || '').toLocaleLowerCase().includes(range.query.trim().toLocaleLowerCase())).slice(0, 30);
            if (range.query.trim()) choices.push(null);
            active = Math.min(active, Math.max(0, choices.length - 1));
            el.replaceChildren();
            choices.forEach((choice, index) => {
              const button = document.createElement('button');
              button.type = 'button'; button.setAttribute('role', 'option'); button.setAttribute('aria-selected', String(index === active));
              button.textContent = choice ? `${choice.title} · ${choice.record_id.slice(0, 8)}` : `Create “${range.query.trim()}”`;
              button.disabled = pending;
              button.addEventListener('pointerdown', (event) => event.preventDefault());
              button.addEventListener('click', () => { void choose(index); });
              el.append(button);
            });
            if (!choices.length) el.textContent = 'Type a page name to search or create';
            const rect = view.coordsAtPos(view.state.selection.from);
            el.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - Math.min(360, window.innerWidth - 16)))}px`;
            el.style.top = `${Math.max(8, Math.min(rect.bottom + 4, window.innerHeight - 240))}px`;
          };
          picker = { keydown(event) {
            if (el.hidden || pending) return false;
            if (event.key === 'Escape') { dismissed = signature; el.hidden = true; return true; }
            if (['ArrowDown', 'ArrowUp'].includes(event.key)) { active = (active + (event.key === 'ArrowDown' ? 1 : -1) + choices.length) % Math.max(1, choices.length); render(); return true; }
            if (event.key === 'Enter' && choices.length) { void choose(active); return true; }
            return false;
          } };
          render();
          return { update: render, destroy() { el.remove(); picker = null; } };
        },
      })];
    },
  });
}
