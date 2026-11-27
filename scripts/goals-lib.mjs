// Ambulando Goals: the `ambulando.goal` v1 format and expectation-checked edits, shared in behaviour with the Android
// (core/goals) and Mac (AmbulandoCore/Goals) implementations. Pure functions; no network, no keys.

export const SCHEMA = 'ambulando.goal';
export const VERSION = 1;
export const MIME = 'application/vnd.ambulando.goal+json';
export const SYSTEM_KEY = 'ambulando.goals';
export const MAX_BYTES = 256 * 1024;
const KNOWN = ['schema', 'schema_version', 'name', 'description', 'start_date', 'target_date', 'status', 'checkpoints', 'links'];
const CP_KNOWN = ['id', 'title', 'date', 'description', 'reached'];
const LINK_KNOWN = ['type', 'record_id', 'channel_id'];
const STATUSES = ['active', 'completed', 'archived'];
const LINK_TYPES = ['chat', 'task', 'doc', 'file'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CP_ID = /^[A-Za-z0-9_-]{1,64}$/;

export class GoalError extends Error {
  constructor(kind, message) { super(message); this.kind = kind; }
}
const invalid = message => new GoalError('invalid', message);
const conflict = message => new GoalError('conflict', message);

const clean = v => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);
const unknown = (o, known) => Object.fromEntries(Object.entries(o).filter(([k]) => !known.includes(k)));

export function validDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}
const requireDate = v => { if (!validDate(v)) throw invalid('Dates use the form 2026-12-18.'); };

export function validate(goal) {
  if (!clean(goal.name)) throw invalid('A goal needs a name.');
  if (!clean(goal.description)) throw invalid('A goal needs a description.');
  if (goal.name.length > 120) throw invalid('The name is too long.');
  if (goal.description.length > 2000) throw invalid('The description is too long.');
  if (goal.start_date != null) requireDate(goal.start_date);
  if (goal.target_date != null) requireDate(goal.target_date);
  if (goal.start_date != null && goal.target_date != null && goal.target_date < goal.start_date) throw invalid('The target date is before the start date.');
  if (!STATUSES.includes(goal.status)) throw invalid('Unknown goal status.');
  if (goal.checkpoints.length > 100) throw invalid('Too many checkpoints.');
  if (new Set(goal.checkpoints.map(c => c.id)).size !== goal.checkpoints.length) throw invalid('Checkpoint identities repeat.');
  for (const c of goal.checkpoints) {
    if (!CP_ID.test(c.id ?? '')) throw invalid('A checkpoint identity is invalid.');
    if (!clean(c.title)) throw invalid('A checkpoint needs a title.');
    if (c.title.length > 120) throw invalid('A checkpoint title is too long.');
    if ((c.description ?? '').length > 500) throw invalid('A checkpoint description is too long.');
    if (c.date != null) requireDate(c.date);
  }
  if (goal.links.length > 500) throw invalid('Too many linked records.');
  if (new Set(goal.links.map(l => `${l.type}:${l.record_id}`)).size !== goal.links.length) throw invalid('A record is linked twice.');
  for (const l of goal.links) {
    if (!LINK_TYPES.includes(l.type)) throw invalid('A link has an unknown type.');
    if (!UUID.test(l.record_id ?? '')) throw invalid('A linked record identity is invalid.');
    if (l.channel_id != null && !UUID.test(l.channel_id)) throw invalid('A linked channel identity is invalid.');
  }
  if (goal.default_channel_id != null && (typeof goal.default_channel_id !== 'string' || !UUID.test(goal.default_channel_id))) throw invalid('Invalid default discussion channel.');
  if (goal.pinned_refs != null) {
    if (!Array.isArray(goal.pinned_refs) || goal.pinned_refs.length > 100) throw invalid('Too many pinned references.');
    const seen = new Set();
    for (const pin of goal.pinned_refs) {
      if (!pin || !['doc','file'].includes(pin.type) || !UUID.test(pin.record_id ?? '') || (pin.channel_id != null && !UUID.test(pin.channel_id))) throw invalid('Invalid pinned reference.');
      const key=pin.type+':'+pin.record_id;if(seen.has(key)) throw invalid('A reference is pinned twice.');seen.add(key);
    }
  }
  return goal;
}

/** Reads stored bytes. An unsupported or malformed goal is refused, never partially shown or rewritten. */
export function parse(bytes) {
  if (bytes.length > MAX_BYTES) throw invalid('This goal is too large to read.');
  let root;
  try { root = JSON.parse(Buffer.from(bytes).toString('utf8'), (key,value,context) => typeof value === 'number' && context?.source && JSON.stringify(value)!==context.source ? JSON.rawJSON(context.source) : value); } catch { throw invalid('This goal could not be read.'); }
  if (!root || typeof root !== 'object' || Array.isArray(root)) throw invalid('This goal could not be read.');
  if (root.schema !== SCHEMA) throw invalid('This is not a goal.');
  if (root.schema_version !== VERSION) throw new GoalError('unsupported', 'This goal was saved by a newer version of the app. Update to open it.');
  // A known field of the wrong type is an error, never "absent": a goal is rewritten whole, so reading a damaged field as
  // empty would silently erase it (or every checkpoint and link) on the next save.
  const bad = key => invalid(`The goal’s “${key}” has an unexpected form, so it was not opened.`);
  const str = (o, key) => { const v = o[key]; if (v == null) return undefined; if (typeof v !== 'string') throw bad(key); return v; };
  const bool = (o, key) => { const v = o[key]; if (v == null) return false; if (typeof v !== 'boolean') throw bad(key); return v; };
  const list = (o, key) => { const v = o[key]; if (v == null) return []; if (!Array.isArray(v)) throw bad(key); return v; };
  const obj = (v, key) => { if (!v || typeof v !== 'object' || Array.isArray(v)) throw bad(key); return v; };
  const goal = {
    ...unknown(root, KNOWN),
    name: str(root, 'name') ?? '', description: str(root, 'description') ?? '',
    ...(str(root, 'start_date') != null ? { start_date: str(root, 'start_date') } : {}), ...(str(root, 'target_date') != null ? { target_date: str(root, 'target_date') } : {}),
    status: str(root, 'status'),
    checkpoints: list(root, 'checkpoints').map(c => { obj(c, 'checkpoints'); return { ...unknown(c, CP_KNOWN), id: str(c, 'id') ?? '', title: str(c, 'title') ?? '',
      ...(str(c, 'date') != null ? { date: str(c, 'date') } : {}), ...(str(c, 'description') != null ? { description: str(c, 'description') } : {}), reached: bool(c, 'reached') }; }),
    links: list(root, 'links').map(l => { obj(l, 'links'); return { ...unknown(l, LINK_KNOWN), type: str(l, 'type'), record_id: (str(l, 'record_id') ?? '').toLowerCase(),
      ...(str(l, 'channel_id') != null ? { channel_id: str(l, 'channel_id').toLowerCase() } : {}) }; }),
  };
  return validate(goal);
}

export function create({ name, description, start_date, target_date }) {
  const goal = { name: String(name ?? '').trim(), description: String(description ?? '').trim(), status: 'active', checkpoints: [], links: [] };
  if (clean(start_date)) goal.start_date = clean(start_date);
  if (clean(target_date)) goal.target_date = clean(target_date);
  return validate(goal);
}

/** Canonical JSON: known fields in a stable order after any unknown ones, as the other clients write it. */
export function encode(goal) {
  const out = { ...unknown(goal, KNOWN), schema: SCHEMA, schema_version: VERSION, name: goal.name, description: goal.description };
  if (goal.start_date != null) out.start_date = goal.start_date;
  if (goal.target_date != null) out.target_date = goal.target_date;
  out.status = goal.status;
  out.checkpoints = goal.checkpoints.map(c => ({ ...unknown(c, CP_KNOWN), id: c.id, title: c.title, ...(c.date != null ? { date: c.date } : {}), ...(c.description != null ? { description: c.description } : {}), reached: !!c.reached }));
  out.links = goal.links.map(l => ({ ...unknown(l, LINK_KNOWN), type: l.type, record_id: l.record_id, ...(l.channel_id != null ? { channel_id: l.channel_id } : {}) }));
  return Buffer.from(JSON.stringify(out));
}

const editable = goal => { if (goal.status === 'archived') throw conflict('This goal is archived. Restore it to change it.'); };
const same = (a, b) => (a ?? null) === (b ?? null);

function setting(goal, key, label, expected, next) {
  editable(goal);
  if (same(goal[key], next)) return goal;
  if (!same(goal[key], expected)) throw conflict(`The ${label} was changed elsewhere.`);
  const out = { ...goal };
  if (next == null) delete out[key]; else out[key] = next;
  return validate(out);
}

/** One change, checked against the values the editor saw. Throws a `conflict` GoalError when they no longer hold. */
export function applyEdit(goal, edit) {
  switch (edit.op) {
    case 'set_name': return setting(goal, 'name', 'name', edit.expected, String(edit.value ?? '').trim());
    case 'set_description': return setting(goal, 'description', 'description', edit.expected, String(edit.value ?? '').trim());
    case 'set_start_date': return setting(goal, 'start_date', 'start date', edit.expected ?? null, clean(edit.value));
    case 'set_target_date': return setting(goal, 'target_date', 'target date', edit.expected ?? null, clean(edit.value));
    case 'set_default_channel_id': return setting(goal, 'default_channel_id', 'default discussion channel', edit.expected ?? null, edit.value ?? null);
    case 'pin': {
      editable(goal);const link={type:edit.type,record_id:String(edit.record_id??'').toLowerCase(),...(edit.channel_id?{channel_id:String(edit.channel_id).toLowerCase()}: {})};
      if((goal.pinned_refs??[]).some(p=>p.type===link.type&&p.record_id===link.record_id))return goal;
      return validate({...goal,pinned_refs:[...(goal.pinned_refs??[]),link]});
    }
    case 'unpin': editable(goal);return validate({...goal,pinned_refs:(goal.pinned_refs??[]).filter(p=>p.type!==edit.type||p.record_id!==edit.record_id)});
    case 'set_status': {
      if (!STATUSES.includes(edit.value)) throw invalid('Unknown goal status.');
      if (goal.status === edit.value) return goal;
      if (goal.status !== edit.expected) throw conflict(`This goal was ${goal.status} elsewhere.`);
      return validate({ ...goal, status: edit.value });
    }
    case 'add_checkpoint': {
      editable(goal);
      const cp = { id: edit.checkpoint?.id ?? crypto.randomUUID(), title: edit.checkpoint?.title ?? '', reached: false,
        ...(clean(edit.checkpoint?.date) ? { date: clean(edit.checkpoint.date) } : {}), ...(clean(edit.checkpoint?.description) ? { description: clean(edit.checkpoint.description) } : {}) };
      if (goal.checkpoints.some(c => c.id === cp.id)) return goal;
      const after = goal.checkpoints.findIndex(c => c.id === edit.after);
      const at = after < 0 ? goal.checkpoints.length : after + 1;
      const checkpoints = [...goal.checkpoints]; checkpoints.splice(at, 0, { ...cp, title: cp.title.trim() });
      return validate({ ...goal, checkpoints });
    }
    case 'update_checkpoint': {
      editable(goal);
      const i = goal.checkpoints.findIndex(c => c.id === edit.id);
      if (i < 0) throw conflict('That checkpoint was removed elsewhere.');
      const cur = goal.checkpoints[i];
      const body = c => [c.title, c.date ?? null, c.description ?? null];
      const value = edit.value ?? {};
      const next = { ...cur, title: String(value.title ?? '').trim() };
      for (const k of ['date', 'description']) { const v = clean(value[k]); if (v) next[k] = v; else delete next[k]; }
      if (JSON.stringify(body(cur)) === JSON.stringify(body(next))) return goal;
      const exp = edit.expected ?? {};
      if (JSON.stringify(body(cur)) !== JSON.stringify([String(exp.title ?? '').trim(), clean(exp.date), clean(exp.description)])) throw conflict(`“${cur.title}” was changed elsewhere.`);
      return validate({ ...goal, checkpoints: goal.checkpoints.map((c, n) => (n === i ? next : c)) });
    }
    case 'set_reached': {
      editable(goal);
      const i = goal.checkpoints.findIndex(c => c.id === edit.id);
      if (i < 0) throw conflict('That checkpoint was removed elsewhere.');
      const cur = goal.checkpoints[i];
      if (cur.reached === !!edit.reached) return goal;
      if (cur.reached !== !!edit.expected) throw conflict(`“${cur.title}” was changed elsewhere.`);
      return { ...goal, checkpoints: goal.checkpoints.map((c, n) => (n === i ? { ...c, reached: !!edit.reached } : c)) };
    }
    case 'remove_checkpoint': editable(goal); return { ...goal, checkpoints: goal.checkpoints.filter(c => c.id !== edit.id) };
    case 'move_checkpoint': {
      editable(goal);
      const item = goal.checkpoints.find(c => c.id === edit.id);
      if (!item) throw conflict('That checkpoint was removed elsewhere.');
      const rest = goal.checkpoints.filter(c => c.id !== edit.id);
      rest.splice(Math.min(Math.max(Number(edit.to_index) || 0, 0), rest.length), 0, item);
      return { ...goal, checkpoints: rest };
    }
    case 'link': {
      editable(goal);
      const link = { type: edit.type, record_id: String(edit.record_id ?? '').toLowerCase(), ...(edit.channel_id ? { channel_id: String(edit.channel_id).toLowerCase() } : {}) };
      if (goal.links.some(l => l.type === link.type && l.record_id === link.record_id)) return goal;
      return validate({ ...goal, links: [...goal.links, link] });
    }
    case 'set_focus_rank': {
      // Focus order lives in the optional `focus_rank` field (see focusOrder). It stays in the unknown-field area so
      // clients that predate it keep it byte for byte.
      editable(goal);
      const value = edit.value ?? null;
      if (value !== null && !validRank(value)) throw invalid('A focus rank is invalid.');
      const current = focusRank(goal);
      if (current === value) return goal;
      if (current !== (edit.expected ?? null)) throw conflict('The goal order was changed elsewhere.');
      const out = { ...goal };
      if (value === null) delete out.focus_rank; else out.focus_rank = value;
      return out;
    }
    case 'unlink': editable(goal); return { ...goal, links: goal.links.filter(l => !(l.type === edit.type && l.record_id === String(edit.record_id ?? '').toLowerCase())) };
    default: throw invalid(`Unknown edit "${edit.op}".`);
  }
}

export const applyAll = (goal, edits) => edits.reduce(applyEdit, goal);

/**
 * Applies `edits` to the newest saved goal and saves them as one new version against that head. A lost compare-and-swap
 * race re-applies the edits to the new head; an edit whose expectation no longer holds throws and saves nothing.
 * `store.read()` → { versionId, goal }; `store.save(baseVersionId, bytes)` → { saved: versionId } | { conflict: true }.
 */
export async function editWithRetry(store, edits, attempts = 4) {
  let head = await store.read();
  for (let i = 0; i < attempts; i++) {
    const next = applyAll(head.goal, edits);
    if (JSON.stringify(encode(next)) === JSON.stringify(encode(head.goal))) return { ...head, changed: false };
    const result = await store.save(head.versionId, encode(next));
    if (result.saved) return { versionId: result.saved, goal: next, changed: true };
    head = await store.read();
  }
  throw new GoalError('busy', 'This goal is being changed elsewhere. Try again in a moment.');
}

/** Whether a channel's grants allow it to hold `owner`'s goals: the owner, plus only workspace agents. */
export function classifyGrants({ grants, members, owner }) {
  const agents = new Set(members.filter(m => m.kind === 'agent').map(m => m.actor_id));
  const ownerActor = members.find(m => m.npub === owner)?.actor_id;
  let hasOwner = false;
  for (const g of grants) {
    const id = g.principal?.actor_id ?? g.principal?.id ?? g.principal_id;
    if (g.principal_type === 'group' || g.principal?.type === 'group') return { safe: false, reason: 'shared with a group' };
    if (g.principal?.npub === owner || (id && id === ownerActor)) hasOwner = true;
    else if (!(id && agents.has(id))) return { safe: false, reason: 'shared with someone other than the owner and agents' };
  }
  return hasOwner ? { safe: true } : { safe: false, reason: 'the owner holds no grant' };
}

export function isOwnedChannel(channel, owner) {
  const meta = channel?.metadata;
  return channel?.kind === 'channel' && !channel.archived_at && channel.record_state !== 'deleted' && channel.is_archived !== true
    && meta?.system_key === SYSTEM_KEY && meta?.goals?.owner_npub === owner;
}

export function isGoalFile(file) {
  const type = String(file?.content_type ?? file?.current_version?.content_type ?? '').split(';')[0].trim().toLowerCase();
  // A soft-deleted File keeps record_state=active and gets deleted_at, so any non-null deleted_at is a tombstone.
  return !file?.archived_at && (file?.deleted_at ?? null) === null && file?.record_state !== 'deleted' && file?.record_state !== 'archived' && type === MIME && file?.metadata?.goal?.schema_version === VERSION;
}

// Focus order. A goal may carry `focus_rank`: a fractional-index key of 1–64 characters from FOCUS_DIGITS (ASCII order)
// not ending in the lowest digit. Keys compare by code unit; a key exists strictly between any two distinct keys, so a
// move usually rewrites only the moved goal (more when unranked goals above it must be ranked first, or on a rebalance;
// see planMove). Each write is one expectation-checked set_focus_rank edit. Anything else in `focus_rank` (wrong type, bad character, too long) reads
// as unranked and is kept untouched until a valid rank replaces it. Shared fixture: docs/fixtures/goals/focus-order-v1.json.
export const FOCUS_DIGITS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
export const MAX_RANK = 64;
const RANK = /^[0-9A-Za-z]{0,63}[1-9A-Za-z]$/;

export const validRank = value => typeof value === 'string' && RANK.test(value);
export const focusRank = goal => (validRank(goal.focus_rank) ? goal.focus_rank : null);

/**
 * A key strictly between `a` and `b` (`null` = no bound). Port of the midpoint of David Greenspan's
 * "Implementing Fractional Indexing" (MIT `fractional-indexing`), without its integer header so every key is a plain
 * fraction. The Swift (GoalFocus.swift) and Kotlin ports must return the same keys; the fixture pins them.
 */
export function keyBetween(a, b) {
  const lo = a ?? '';
  if ((lo !== '' && !validRank(lo)) || (b != null && !validRank(b))) throw invalid('A focus rank is invalid.');
  if (b != null && lo >= b) throw invalid('Focus ranks are out of order.');
  return midpoint(lo, b ?? null);
}

function midpoint(a, b) {
  if (b !== null) {
    let n = 0;
    while ((a[n] ?? '0') === b[n]) n++;
    if (n > 0) return b.slice(0, n) + midpoint(a.slice(n), b.slice(n));
  }
  const da = a ? FOCUS_DIGITS.indexOf(a[0]) : 0;
  const db = b !== null ? FOCUS_DIGITS.indexOf(b[0]) : FOCUS_DIGITS.length;
  if (db - da > 1) return FOCUS_DIGITS[Math.floor((da + db + 1) / 2)];
  if (b !== null && b.length > 1) return b.slice(0, 1);
  return FOCUS_DIGITS[da] + midpoint(a.slice(1), null);
}

/** `n` evenly spaced short keys, in order: the rebalance used when no key fits (ties, or a key would exceed MAX_RANK). */
export function evenKeys(n) {
  const base = FOCUS_DIGITS.length;
  let width = 1;
  while (base ** width - 1 < n) width++;
  const span = base ** width;
  return Array.from({ length: n }, (_, j) => {
    let v = Math.floor(((j + 1) * span) / (n + 1)), key = '';
    for (let i = 0; i < width; i++) { key = FOCUS_DIGITS[v % base] + key; v = Math.floor(v / base); }
    return key.replace(/0+$/, '');
  });
}

const STATUS_RANK = { active: 0, completed: 1, archived: 2 };
const asciiFold = s => s.replace(/[A-Z]/g, c => String.fromCharCode(c.charCodeAt(0) + 32));
const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);

/**
 * The one goal order on every client, for `{ id, goal }` items: status (active, completed, archived); then ranked goals
 * by `focus_rank`, before unranked ones; unranked by target date (none last), then name with only A–Z folded; equal keys
 * by file id. Every comparison is by UTF-16 code unit, so Swift, Kotlin and JS agree.
 */
export function compareFocus(a, b) {
  const ra = focusRank(a.goal), rb = focusRank(b.goal);
  return cmp(STATUS_RANK[a.goal.status] ?? 3, STATUS_RANK[b.goal.status] ?? 3)
    || cmp(ra === null ? 1 : 0, rb === null ? 1 : 0)
    || (ra !== null && rb !== null ? cmp(ra, rb) : 0)
    || (ra === null ? cmp(a.goal.target_date ?? '9999-12-31', b.goal.target_date ?? '9999-12-31') || cmp(asciiFold(a.goal.name), asciiFold(b.goal.name)) : 0)
    || cmp(a.id, b.id);
}
export const focusOrder = items => [...items].sort(compareFocus);

/**
 * The rank writes that move goal `id` to `toIndex` in `items` (one status group, already in focusOrder). Returns
 * `[{ id, expected, value }]`, top first; each becomes a `set_focus_rank` edit on that goal.
 * - Usually one write: a key between the new neighbours.
 * - Ranked goals sort before unranked ones, so placing a goal below an unranked goal first ranks the unranked goals
 *   above it, in their current order.
 * - Neighbours with equal keys (two devices picked the same key) or a key longer than MAX_RANK rebalance: every goal
 *   from the top through the last ranked one (or the moved goal) gets evenKeys, writing only the keys that change.
 */
export function planMove(items, id, toIndex) {
  const moving = items.find(i => i.id === id);
  if (!moving) throw conflict('That goal was removed elsewhere.');
  const rest = items.filter(i => i.id !== id);
  const at = Math.min(Math.max(toIndex, 0), rest.length);
  const next = [...rest.slice(0, at), moving, ...rest.slice(at)];
  if (next.every((item, n) => item.id === items[n].id)) return [];
  const ranks = next.map(i => focusRank(i.goal));
  const writes = [];
  let lo = null, fits = true;
  for (let n = 0; n <= at; n++) {
    if (n < at && ranks[n] !== null) { lo = ranks[n]; continue; }
    const hi = n === at && n + 1 < next.length ? ranks[n + 1] : null;
    if (hi !== null && lo !== null && lo >= hi) { fits = false; break; }
    const key = keyBetween(lo, hi);
    if (key.length > MAX_RANK) { fits = false; break; }
    writes.push({ id: next[n].id, expected: ranks[n], value: key });
    lo = key;
  }
  if (fits) return writes;
  const last = Math.max(at, ranks.reduce((m, r, n) => (r !== null ? n : m), -1));
  const keys = evenKeys(last + 1);
  return next.slice(0, last + 1).flatMap((item, n) => (ranks[n] === keys[n] ? [] : [{ id: item.id, expected: ranks[n], value: keys[n] }]));
}
