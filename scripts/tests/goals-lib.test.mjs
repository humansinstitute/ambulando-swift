import { expect, test } from 'bun:test';
import * as lib from '../goals-lib.mjs';

const id1 = '11111111-1111-4111-8111-111111111111', id2 = '22222222-2222-4222-8222-222222222222';

/** The same bytes are asserted by AmbulandoCore's GoalsTests, so both clients write one canonical form. */
export const CANONICAL = '{"future":{"a":[1,2.5]},"schema":"ambulando.goal","schema_version":1,"name":"Ship the beta","description":"Get the beta to ten people.",'
  + '"start_date":"2026-12-01","target_date":"2026-12-18","status":"active","checkpoints":[{"id":"a","title":"Invite list","reached":true},'
  + '{"id":"b","title":"Build","date":"2026-12-10","description":"Ready to ship","reached":false}],'
  + `"links":[{"type":"task","record_id":"${id1}"},{"type":"chat","record_id":"${id2}","channel_id":"${id1}"}]}`;

const base = () => lib.parse(Buffer.from(CANONICAL));

test('canonical form round-trips byte for byte and keeps unknown fields', () => {
  expect(lib.encode(base()).toString()).toBe(CANONICAL);
});

test('refuses unsupported, foreign and malformed content', () => {
  expect(() => lib.parse(Buffer.from('{"schema":"ambulando.goal","schema_version":2,"name":"n","description":"d","status":"active"}'))).toThrow(/newer version/);
  expect(() => lib.parse(Buffer.from('{"schema":"x","schema_version":1}'))).toThrow(/not a goal/);
  expect(() => lib.parse(Buffer.from('[]'))).toThrow();
  expect(() => lib.parse(Buffer.from('{"schema":"ambulando.goal","schema_version":1,"name":"n","description":"d","status":"paused"}'))).toThrow(/status/);
});

test('validation rules', () => {
  expect(() => lib.create({ name: ' ', description: 'd' })).toThrow(/needs a name/);
  expect(() => lib.create({ name: 'n', description: '' })).toThrow(/needs a description/);
  expect(() => lib.create({ name: 'n', description: 'd', start_date: '2026-12-18', target_date: '2026-12-01' })).toThrow(/before the start/);
  expect(() => lib.create({ name: 'n', description: 'd', start_date: '2026-02-30' })).toThrow(/Dates use/);
  expect(() => lib.create({ name: 'n', description: 'd', target_date: '2026-1-5' })).toThrow(/Dates use/);
  expect(lib.create({ name: 'n', description: 'd', start_date: ' ' }).start_date).toBeUndefined();
});

test('edits check what the editor saw, and are idempotent when already in effect', () => {
  const g = base();
  expect(lib.applyEdit(g, { op: 'set_name', expected: 'Ship the beta', value: ' v1 ' }).name).toBe('v1');
  expect(() => lib.applyEdit(g, { op: 'set_name', expected: 'Old', value: 'X' })).toThrow(/changed elsewhere/);
  expect(lib.applyEdit(g, { op: 'set_name', expected: 'Old', value: 'Ship the beta' })).toBe(g);
  expect(lib.applyEdit(g, { op: 'set_target_date', expected: '2026-12-18', value: null }).target_date).toBeUndefined();
  expect(() => lib.applyEdit(g, { op: 'set_target_date', expected: '2026-12-18', value: '2026-11-01' })).toThrow(/before the start/);
});

test('checkpoints: reach, reorder, update, remove', () => {
  const g = base();
  expect(lib.applyEdit(g, { op: 'set_reached', id: 'b', expected: false, reached: true }).checkpoints.map(c => c.reached)).toEqual([true, true]);
  expect(lib.applyEdit(g, { op: 'set_reached', id: 'a', expected: true, reached: true })).toBe(g);
  expect(() => lib.applyEdit(g, { op: 'set_reached', id: 'zz', expected: false, reached: true })).toThrow(/removed elsewhere/);
  expect(lib.applyEdit(g, { op: 'move_checkpoint', id: 'b', to_index: 0 }).checkpoints.map(c => c.id)).toEqual(['b', 'a']);
  const added = lib.applyEdit(g, { op: 'add_checkpoint', checkpoint: { id: 'n', title: 'New' }, after: 'a' });
  expect(added.checkpoints.map(c => c.id)).toEqual(['a', 'n', 'b']);
  const updated = lib.applyEdit(g, { op: 'update_checkpoint', id: 'b', expected: { title: 'Build', date: '2026-12-10', description: 'Ready to ship' }, value: { title: 'Build it', date: '2026-12-11' } });
  expect(updated.checkpoints[1]).toMatchObject({ title: 'Build it', date: '2026-12-11', reached: false });
  expect(updated.checkpoints[1].description).toBeUndefined();
  expect(() => lib.applyEdit(g, { op: 'update_checkpoint', id: 'b', expected: { title: 'Older' }, value: { title: 'X' } })).toThrow(/changed elsewhere/);
  expect(lib.applyEdit(g, { op: 'remove_checkpoint', id: 'a' }).checkpoints.map(c => c.id)).toEqual(['b']);
});

test('links are references; unlinking changes only the link list; archived goals refuse edits', () => {
  const g = base();
  const doc = '33333333-3333-4333-8333-333333333333';
  const linked = lib.applyEdit(g, { op: 'link', type: 'doc', record_id: doc.toUpperCase() });
  expect(linked.links.length).toBe(3);
  expect(lib.applyEdit(linked, { op: 'link', type: 'doc', record_id: doc })).toBe(linked);
  expect(lib.applyEdit(linked, { op: 'unlink', type: 'doc', record_id: doc })).toEqual(g);
  expect(() => lib.applyEdit(g, { op: 'link', type: 'file', record_id: 'nope' })).toThrow(/identity is invalid/);
  const done = lib.applyEdit(g, { op: 'set_status', expected: 'active', value: 'completed' });
  expect(done.checkpoints).toEqual(g.checkpoints); expect(done.links).toEqual(g.links);
  const archived = lib.applyEdit(done, { op: 'set_status', expected: 'completed', value: 'archived' });
  expect(() => lib.applyEdit(archived, { op: 'set_name', expected: 'Ship the beta', value: 'x' })).toThrow(/archived/);
  expect(lib.applyEdit(archived, { op: 'set_status', expected: 'archived', value: 'active' }).links).toEqual(g.links);
  expect(() => lib.applyEdit(archived, { op: 'set_status', expected: 'active', value: 'completed' })).toThrow(/archived elsewhere/);
});

function memoryStore(goal) {
  const versions = [{ id: 'v1', bytes: lib.encode(goal) }];
  const store = {
    versions, interject: null,
    read: async () => ({ versionId: versions.at(-1).id, goal: lib.parse(versions.at(-1).bytes) }),
    save: async (base, bytes) => {
      if (store.interject) { const f = store.interject; store.interject = null; f(); }
      if (versions.at(-1).id !== base) return { conflict: true };
      versions.push({ id: `v${versions.length + 1}`, bytes }); return { saved: versions.at(-1).id };
    },
  };
  return store;
}

test('a lost race re-applies independent edits; a contradiction saves nothing', async () => {
  const store = memoryStore(base());
  store.interject = () => store.versions.push({ id: 'v-other', bytes: lib.encode(lib.applyEdit(lib.parse(store.versions.at(-1).bytes), { op: 'set_name', expected: 'Ship the beta', value: 'Renamed' })) });
  const result = await lib.editWithRetry(store, [{ op: 'set_reached', id: 'b', expected: false, reached: true }]);
  const saved = lib.parse(store.versions.at(-1).bytes);
  expect(saved.name).toBe('Renamed'); expect(saved.checkpoints[1].reached).toBe(true); expect(result.changed).toBe(true);
  const second = memoryStore(base());
  second.interject = () => second.versions.push({ id: 'v-other', bytes: lib.encode(lib.applyEdit(lib.parse(second.versions.at(-1).bytes), { op: 'set_name', expected: 'Ship the beta', value: 'Theirs' })) });
  await expect(lib.editWithRetry(second, [{ op: 'set_name', expected: 'Ship the beta', value: 'Mine' }])).rejects.toThrow(/changed elsewhere/);
  expect(lib.parse(second.versions.at(-1).bytes).name).toBe('Theirs');
  const idle = memoryStore(base());
  expect((await lib.editWithRetry(idle, [{ op: 'set_name', expected: 'Ship the beta', value: 'Ship the beta' }])).changed).toBe(false);
  expect(idle.versions.length).toBe(1);
});

test('a space is only safe when shared with the owner and agents alone', () => {
  const owner = 'npub1owner', members = [{ actor_id: 'o', npub: owner, kind: 'human' }, { actor_id: 'r', npub: 'npub1rick', kind: 'agent' }, { actor_id: 's', npub: 'npub1sam', kind: 'human' }];
  const g = (id, extra = {}) => ({ principal: { actor_id: id }, principal_type: 'actor', access_level: 'manage', ...extra });
  expect(lib.classifyGrants({ grants: [g('o'), g('r')], members, owner }).safe).toBe(true);
  expect(lib.classifyGrants({ grants: [g('o'), g('s')], members, owner }).safe).toBe(false);
  expect(lib.classifyGrants({ grants: [g('o'), g('x', { principal_type: 'group' })], members, owner }).safe).toBe(false);
  expect(lib.classifyGrants({ grants: [g('r')], members, owner }).safe).toBe(false);
  const channel = { kind: 'channel', metadata: { system_key: lib.SYSTEM_KEY, goals: { owner_npub: owner } } };
  expect(lib.isOwnedChannel(channel, owner)).toBe(true);
  expect(lib.isOwnedChannel(channel, 'npub1other')).toBe(false);
  expect(lib.isOwnedChannel({ ...channel, archived_at: 'x' }, owner)).toBe(false);
});

test('only current goal files count', () => {
  const file = { content_type: `${lib.MIME}; charset=utf-8`, metadata: { goal: { schema_version: 1 } } };
  expect(lib.isGoalFile(file)).toBe(true);
  expect(lib.isGoalFile({ ...file, content_type: 'application/json' })).toBe(false);
  expect(lib.isGoalFile({ ...file, metadata: { goal: { schema_version: 2 } } })).toBe(false);
  expect(lib.isGoalFile({ ...file, record_state: 'deleted' })).toBe(false);
  // Live soft delete: record_state stays active, deleted_at is set.
  expect(lib.isGoalFile({ ...file, record_state: 'active', deleted_at: '2026-11-26T08:00:00.000Z' })).toBe(false);
  expect(lib.isGoalFile({ ...file, record_state: 'active', deleted_at: null })).toBe(true);
});

// The goal as Android writes it, shared with AmbulandoCore's GoalGoldenFixtureTests.
import { readFileSync } from 'node:fs';
const fixtureUrl = new URL('../../docs/fixtures/goals/android-written-v1.json', import.meta.url);
const golden = () => readFileSync(fixtureUrl);

test('golden: an Android-written goal survives an agent edit with every unknown field intact', () => {
  const original = JSON.parse(golden());
  const edited = lib.applyAll(lib.parse(golden()), [{ op: 'set_reached', id: 'cp-2', expected: false, reached: true }, { op: 'link', type: 'file', record_id: '55555555-5555-4555-8555-555555555555' }]);
  const written = JSON.parse(lib.encode(edited));
  expect(written.future_top).toEqual(original.future_top);
  expect(written.checkpoints[0]).toEqual(original.checkpoints[0]);
  expect(written.checkpoints[1]).toEqual({ ...original.checkpoints[1], reached: true });
  expect(written.links.slice(0, 3)).toEqual(original.links);
  expect(written.links.length).toBe(4);
  expect(lib.parse(lib.encode(edited))).toEqual(edited);
  // Semantic equality: key order of unknown fields and number spelling need not round-trip.
  expect(JSON.parse(lib.encode(lib.parse(golden())))).toEqual(original);
});

test('golden: emoji lengths are UTF-16 like Android; damaged known fields are refused, not erased', () => {
  expect(lib.create({ name: '🚀'.repeat(60), description: 'd' }).name.length).toBe(120);
  expect(() => lib.create({ name: '🚀'.repeat(61), description: 'd' })).toThrow(/too long/);
  const base = JSON.parse(golden());
  for (const change of [o => { o.checkpoints = 'oops'; }, o => { o.links = ['x']; }, o => { o.name = 5; }, o => { o.description = ['a']; }, o => { o.target_date = 20261218; },
    o => { o.checkpoints = [{ id: 'a', title: 'T', reached: 'yes' }]; }, o => { o.checkpoints = [{ id: 'a', title: 3 }]; }, o => { o.links = [{ type: 'task', record_id: 7 }]; },
    o => { o.links = [{ type: 'task', record_id: '11111111-1111-4111-8111-111111111111', channel_id: 1 }]; }]) {
    const copy = structuredClone(base); change(copy);
    expect(() => lib.parse(Buffer.from(JSON.stringify(copy)))).toThrow();
  }
});

// Focus order: the same fixture is asserted by AmbulandoCore's GoalFocusTests and Android's core/goals tests.
const focus = JSON.parse(readFileSync(new URL('../../docs/fixtures/goals/focus-order-v1.json', import.meta.url)));
const focusItem = it => ({ id: it.id, goal: lib.parse(Buffer.from(JSON.stringify(it.goal))) });

test('focus ranks: alphabet, validity, keys between and rebalance keys match the shared fixture', () => {
  expect(lib.FOCUS_DIGITS).toBe(focus.digits);
  expect(lib.MAX_RANK).toBe(focus.max_length);
  for (const v of focus.valid) expect(lib.validRank(v)).toBe(true);
  for (const v of focus.invalid) expect(lib.validRank(v)).toBe(false);
  for (const { a, b, key } of focus.between) {
    expect(lib.keyBetween(a, b)).toBe(key);
    if (a !== null) expect(a < key).toBe(true);
    if (b !== null) expect(key < b).toBe(true);
  }
  for (const { a, b } of focus.between_errors) expect(() => lib.keyBetween(a, b)).toThrow();
  for (const { n, keys } of focus.even_keys) {
    expect(lib.evenKeys(n)).toEqual(keys);
    expect(keys.every(lib.validRank) && keys.every((k, i) => i === 0 || keys[i - 1] < k)).toBe(true);
  }
});

test('focus order and move plans match the shared fixture', () => {
  expect(lib.focusOrder(focus.order.items.map(focusItem)).map(i => i.id)).toEqual(focus.order.expected);
  for (const m of focus.moves) {
    const items = lib.focusOrder(m.items.map(focusItem));
    expect([m.name, lib.planMove(items, m.id, m.to_index)]).toEqual([m.name, m.writes]);
    // Applying the writes produces the requested order.
    const byId = new Map(items.map(i => [i.id, i]));
    for (const w of m.writes) { const it = byId.get(w.id); byId.set(w.id, { ...it, goal: lib.applyEdit(it.goal, { op: 'set_focus_rank', expected: w.expected, value: w.value }) }); }
    const wanted = items.filter(i => i.id !== m.id); wanted.splice(Math.min(m.to_index, wanted.length), 0, items.find(i => i.id === m.id));
    expect([m.name, lib.focusOrder([...byId.values()]).map(i => i.id)]).toEqual([m.name, wanted.map(i => i.id)]);
  }
});

test('set_focus_rank is an expectation-checked edit that keeps the field in place', () => {
  const c = focus.canonical;
  const set = (bytes, expected, value) => lib.encode(lib.applyEdit(lib.parse(Buffer.from(bytes)), { op: 'set_focus_rank', expected, value })).toString();
  expect(set(c.before, c.set.expected, c.set.value)).toBe(c.set.after);
  expect(set(c.set.after, c.move.expected, c.move.value)).toBe(c.move.after);
  expect(set(c.set.after, c.clear.expected, c.clear.value)).toBe(c.clear.after);
  expect(lib.encode(lib.parse(Buffer.from(c.invalid_kept.bytes))).toString()).toBe(c.invalid_kept.round_trip);
  expect(lib.focusRank(lib.parse(Buffer.from(c.invalid_kept.bytes)))).toBe(null);
  expect(set(c.invalid_kept.bytes, null, 'V')).toBe(c.invalid_kept.replaced);
  expect(() => set(c.stale.bytes, c.stale.expected, c.stale.value)).toThrow(/order was changed elsewhere/);
  expect(() => set(c.invalid_value.bytes, c.invalid_value.expected, c.invalid_value.value)).toThrow(/focus rank is invalid/);
  const archived = { ...lib.parse(Buffer.from(c.before)), status: 'archived' };
  expect(() => lib.applyEdit(archived, { op: 'set_focus_rank', expected: null, value: 'V' })).toThrow(/archived/);
});
