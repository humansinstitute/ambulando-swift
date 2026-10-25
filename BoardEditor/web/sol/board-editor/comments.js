import { createElement as h, useImperativeHandle, useState } from 'react';
import { commentAnchor, commentPosition, COMMENT_LIMITS } from '../board-comments.js';
import './comments.css';

// DOM overlay: never drawing elements, so image exports contain no pins/text.
export function BoardComments({ comments, readOnly, send, ref, api }) {
  const [elements, setElements] = useState(() => api?.getSceneElementsIncludingDeleted() || []);
  const [viewport, setViewport] = useState(() => { const state = api?.getAppState(); return { scrollX: state?.scrollX || 0, scrollY: state?.scrollY || 0, zoom: state?.zoom?.value || 1 }; });
  useImperativeHandle(ref, () => ({ update(elements, appState) {
    setElements(elements);
    setViewport(previous => previous.scrollX === appState.scrollX && previous.scrollY === appState.scrollY && previous.zoom === appState.zoom.value ? previous : { scrollX: appState.scrollX, scrollY: appState.scrollY, zoom: appState.zoom.value });
  } }), []);
  const [open, setOpen] = useState(false), [placing, setPlacing] = useState(false);
  const [selected, setSelected] = useState(''), [anchor, setAnchor] = useState(null);
  const [body, setBody] = useState(''), [showResolved, setShowResolved] = useState(false);
  const thread = comments.find(t => t.id === selected);
  const screen = point => ({ left: (point.x + viewport.scrollX) * viewport.zoom, top: (point.y + viewport.scrollY) * viewport.zoom });
  const choose = t => { setSelected(t.id); setAnchor(null); setBody(''); setOpen(true); setPlacing(false); };
  const button = (label, onClick, props = {}) => h('button', { type: 'button', onClick, ...props }, label);
  const submit = event => {
    event.preventDefault();
    if (!body.trim() || readOnly || (!anchor && !thread)) return;
    if (anchor) {
      const id = crypto.randomUUID();
      send({ type: 'create', id, anchor, body }); setSelected(id); setAnchor(null);
    } else send({ type: 'reply', thread_id: thread.id, body });
    setBody('');
  };
  return h('div', { className: 'board-discussion', onKeyDown: event => { event.stopPropagation(); if (event.key === 'Escape') { setPlacing(false); setOpen(false); } } },
    button(`Comments (${comments.filter(t => !t.resolved).length})`, () => { setOpen(!open); setPlacing(false); }, { className: 'board-discussion-toggle', 'aria-expanded': open }),
    placing && !readOnly ? h('div', { className: 'board-comment-place', role: 'button', tabIndex: 0, 'aria-label': 'Choose comment location', onPointerDown: event => {
      event.preventDefault(); event.stopPropagation();
      const rect = event.currentTarget.getBoundingClientRect();
      const point = { x: (event.clientX - rect.left) / viewport.zoom - viewport.scrollX, y: (event.clientY - rect.top) / viewport.zoom - viewport.scrollY };
      setAnchor(commentAnchor(point, elements, !event.altKey)); setSelected(''); setPlacing(false); setOpen(true); setBody('');
    } }, h('span', null, 'Click a shape or board area · Alt-click for a point · Escape to cancel')) : null,
    comments.filter(t => showResolved || !t.resolved).map((t, index) => {
      const p = commentPosition(t.anchor, elements);
      return button(String(index + 1), () => choose(t), { key: t.id, className: `board-comment-pin${t.resolved ? ' resolved' : ''}`, style: screen(p), 'data-thread-id': t.id, 'aria-label': `Open comment: ${t.messages[0].body.slice(0, 80)}`, title: p.detached ? 'Shape removed; last location retained' : 'Open comment' });
    }),
    open ? h('aside', { className: 'board-comment-panel', 'aria-label': 'Board comments', onPointerDown: event => event.stopPropagation(), onWheel: event => event.stopPropagation() },
      h('header', null, h('strong', null, 'Board comments'), button('Close', () => { setOpen(false); setPlacing(false); })),
      h('p', { className: 'board-comment-help' }, readOnly ? 'Read-only board discussion.' : 'Comments are saved with the board. Press Save to publish.'),
      !readOnly ? button(placing ? 'Cancel placement' : 'Add comment', () => { setPlacing(!placing); setOpen(placing); }, { 'aria-pressed': placing }) : null,
      h('label', null, h('input', { type: 'checkbox', checked: showResolved, onChange: event => setShowResolved(event.target.checked) }), 'Show resolved'),
      h('div', { className: 'board-comment-list' }, comments.filter(t => showResolved || !t.resolved).map(t => h('div', { key: t.id, className: 'board-comment-card' },
        button(`${t.resolved ? 'Resolved · ' : ''}${t.messages[0].body.slice(0, 90)} (${t.messages.length})`, () => choose(t), { 'aria-pressed': selected === t.id }))),
      !comments.length ? h('p', null, 'No comments yet.') : null),
      thread || anchor ? h('section', { className: 'board-comment-thread' },
        h('h3', null, anchor ? 'New comment' : thread.resolved ? 'Resolved thread' : 'Comment thread'),
        thread ? h('div', { className: 'board-comment-messages' }, thread.messages.map(message => h('article', { key: message.id },
          h('small', { title: message.author_npub }, `${message.author_npub.slice(0, 16)}… · ${new Date(message.created_at).toLocaleString()}`), h('p', null, message.body)))) : null,
        thread && !readOnly ? button(thread.resolved ? 'Reopen' : 'Resolve', () => send({ type: 'resolve', thread_id: thread.id, resolved: !thread.resolved })) : null,
        !readOnly ? h('form', { onSubmit: submit }, h('textarea', { 'aria-label': thread ? 'Reply' : 'Comment', value: body, maxLength: COMMENT_LIMITS.body, onChange: event => setBody(event.target.value), placeholder: thread ? 'Reply to this thread' : 'Write a comment', autoFocus: true }),
          h('button', { type: 'submit', disabled: !body.trim() }, thread ? 'Add reply' : 'Post comment')) : null) : null) : null);
}
