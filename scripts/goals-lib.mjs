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
  return goal;
}

/** Reads stored bytes. An unsupported or malformed goal is refused, never partially shown or rewritten. */
export function parse(bytes) {
  if (bytes.length > MAX_BYTES) throw invalid('This goal is too large to read.');
  let root;
  try { root = JSON.parse(Buffer.from(bytes).toString('utf8')); } catch { throw invalid('This goal could not be read.'); }
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
