// Board-local discussion data. File versions authenticate the publisher; author
// labels inside JSON are attribution, not independently signed messages.
export const COMMENT_LIMITS = Object.freeze({ threads: 1000, messages: 2000, body: 12000 });
const id = value => typeof value === 'string' && /^[\w-]{1,128}$/.test(value);
const finite = value => Number.isFinite(value) && Math.abs(value) < 1e9;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
export function normalizeBoardComments(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > COMMENT_LIMITS.threads) throw new Error('Invalid board comment threads');
  const ids = new Set();
  return value.map(thread => {
    if (!id(thread?.id) || ids.has(thread.id)) throw new Error('Invalid or duplicate board comment id');
    ids.add(thread.id);
    const a = thread.anchor;
    if (!a || !finite(a.x) || !finite(a.y) || (a.element_id !== undefined && (!id(a.element_id) || !finite(a.u) || !finite(a.v)))) throw new Error('Invalid board comment anchor');
    if (typeof thread.resolved !== 'boolean' || !Array.isArray(thread.messages) || !thread.messages.length || thread.messages.length > COMMENT_LIMITS.messages) throw new Error('Invalid board comment thread');
    const messages = thread.messages.map(message => {
      if (!id(message?.id) || ids.has(message.id) || typeof message.body !== 'string' || !message.body.trim() || message.body.length > COMMENT_LIMITS.body || !/^npub1[\w]{1,100}$/.test(message.author_npub) || !Number.isFinite(Date.parse(message.created_at))) throw new Error('Invalid board comment message');
      ids.add(message.id);
      return { id: message.id, body: message.body, author_npub: message.author_npub, created_at: message.created_at };
    });
    return { id: thread.id, anchor: { x: a.x, y: a.y, ...(a.element_id ? { element_id: a.element_id, u: a.u, v: a.v } : {}) }, resolved: thread.resolved, messages };
  });
}
export const boardComments = scene => scene?.wingman?.comments || [];
export function withBoardComments(scene, comments) {
  return { ...scene, wingman: { ...(scene.wingman || {}), comments: normalizeBoardComments(comments) } };
}
function rotate(x, y, angle) { return { x: x * Math.cos(angle) - y * Math.sin(angle), y: x * Math.sin(angle) + y * Math.cos(angle) }; }
export function commentPosition(anchor, elements) {
  const element = elements.find(e => e.id === anchor.element_id);
  if (!element) return { x: anchor.x, y: anchor.y, detached: Boolean(anchor.element_id) };
  const p = rotate((anchor.u - .5) * element.width, (anchor.v - .5) * element.height, element.angle || 0);
  return { x: element.x + element.width / 2 + p.x, y: element.y + element.height / 2 + p.y, detached: Boolean(element.isDeleted) };
}
export function commentAnchor(point, elements, attach = true) {
  if (attach) for (const element of [...elements].reverse()) {
    if (element.isDeleted || !['rectangle', 'ellipse', 'diamond', 'text', 'image', 'frame'].includes(element.type) || !element.width || !element.height) continue;
    const p = rotate(point.x - element.x - element.width / 2, point.y - element.y - element.height / 2, -(element.angle || 0));
    const u = p.x / element.width + .5, v = p.y / element.height + .5;
    if (u >= 0 && u <= 1 && v >= 0 && v <= 1) return { ...point, element_id: element.id, u, v };
  }
  return { x: point.x, y: point.y };
}
// Update fallback coordinates even when a shape has just become a tombstone.
export function followCommentAnchors(comments, elements) {
  return comments.map(thread => {
    const element = elements.find(e => e.id === thread.anchor.element_id);
    if (!element) return thread;
    const p = commentPosition(thread.anchor, [{ ...element, isDeleted: false }]);
    return { ...thread, anchor: { ...thread.anchor, x: p.x, y: p.y } };
  });
}
export function applyCommentOperation(scene, operation, author, { now = new Date().toISOString(), newId = () => crypto.randomUUID() } = {}) {
  if (!/^npub1[\w]{1,100}$/.test(author || '')) throw new Error('An authenticated board author is required');
  let comments = normalizeBoardComments(boardComments(scene));
  const message = () => ({ id: newId(), body: String(operation.body || '').trim(), author_npub: author, created_at: now });
  if (operation.type === 'create') {
    comments = [...comments, { id: operation.id || newId(), anchor: operation.anchor, resolved: false, messages: [message()] }];
  } else {
    const index = comments.findIndex(t => t.id === operation.thread_id);
    if (index < 0) throw new Error('Comment thread is unavailable');
    comments = comments.map((thread, i) => i !== index ? thread : operation.type === 'reply'
      ? { ...thread, messages: [...thread.messages, message()] }
      : operation.type === 'resolve' && typeof operation.resolved === 'boolean' ? { ...thread, resolved: operation.resolved }
        : (() => { throw new Error('Invalid comment operation'); })());
  }
  return withBoardComments(scene, comments);
}
export function mergeBoardComments(base, draft, latest) {
  const before = new Map(boardComments(base).map(t => [t.id, t]));
  const mine = new Map(boardComments(draft).map(t => [t.id, t]));
  const theirs = new Map(boardComments(latest).map(t => [t.id, t]));
  const conflicts = [];
  const comments = [...new Set([...theirs.keys(), ...mine.keys()])].map(id => {
    const a = before.get(id), b = mine.get(id), c = theirs.get(id);
    if (!b || !c) return b || c;
    const messages = new Map(c.messages.map(m => [m.id, m]));
    for (const message of b.messages) {
      if (messages.has(message.id) && !same(messages.get(message.id), message)) { conflicts.push(`comment:${id}:${message.id}`); continue; }
      messages.set(message.id, message);
    }
    const merged = { ...c, messages: [...messages.values()] };
    for (const field of ['resolved', 'anchor']) {
      if (!same(b[field], a?.[field])) {
        if (!same(c[field], a?.[field]) && !same(c[field], b[field])) conflicts.push(`comment:${id}:${field}`);
        merged[field] = b[field];
      }
    }
    return merged;
  });
  return { comments: normalizeBoardComments(comments), conflicts };
}
export function commentDrawingContext(scene, thread, radius = 240) {
  const elements = scene.elements.filter(e => !e.isDeleted);
  const point = commentPosition(thread.anchor, elements);
  const attached = elements.filter(e => e.id === thread.anchor.element_id);
  const nearby = elements.filter(e => !attached.includes(e) && Math.hypot((e.x + e.width / 2) - point.x, (e.y + e.height / 2) - point.y) <= radius);
  const ids = new Set([...attached, ...nearby].map(e => e.id));
  const connections = elements.filter(e => ids.has(e.startBinding?.elementId) || ids.has(e.endBinding?.elementId) || ids.has(e.containerId));
  const connectedIds = new Set(connections.flatMap(e => [e.startBinding?.elementId, e.endBinding?.elementId, e.containerId]).filter(Boolean));
  const connected = [...new Map([...connections, ...elements.filter(e => connectedIds.has(e.id))].map(e => [e.id, e])).values()];
  return { point, attached, nearby, connected };
}
