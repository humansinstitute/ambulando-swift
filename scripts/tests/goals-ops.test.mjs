import { expect, test } from 'bun:test';
import * as lib from '../goals-lib.mjs';
import { editGoal, sha } from '../goals-ops.mjs';

const WS = 'aaaaaaaa-0000-4000-8000-000000000001', WS_OTHER = 'aaaaaaaa-0000-4000-8000-000000000002';
const CH = 'bbbbbbbb-0000-4000-8000-000000000001', CH_OTHER = 'bbbbbbbb-0000-4000-8000-000000000002';
const GOAL_FILE = 'cccccccc-0000-4000-8000-000000000001', HEAD = 'dddddddd-0000-4000-8000-000000000001';
const T = n => `eeeeeeee-0000-4000-8000-00000000000${n}`;
const ROUTES = { chat: ['threads', 'thread'], task: ['tasks', 'task'], doc: ['docs', 'doc'], file: ['files', 'file'] };

const httpError = (status, code) => Object.assign(new Error(`${status} ${code}`), { status, code });

/** A Tower client double: serves the goal file and typed source routes, records every upload and version save. */
function fakeTower({ sources = {}, goalBytes } = {}) {
  const bytes = goalBytes ?? lib.encode(lib.create({ name: 'Learn to sail', description: 'A first day trip.' }));
  const calls = { gets: [], uploads: [], versions: [] };
  const c = {
    root: `/api/v4/flightdeck-pg/workspaces/${WS}`,
    getFile: async () => ({ file: { id: GOAL_FILE, channel_id: CH, content_type: lib.MIME, metadata: { goal: { schema_version: 1 } }, current_version_id: HEAD } }),
    listVersions: async () => ({ current_version_id: HEAD, versions: [{ id: HEAD, sha256_hex: sha(bytes), size_bytes: bytes.length }] }),
    readVersionBytes: async () => bytes,
    uploadObject: async ({ bytes: b }) => { calls.uploads.push(b); return 'ffffffff-0000-4000-8000-000000000001'; },
    createVersion: async (_f, body) => { calls.versions.push(body); return { version: { id: 'ffffffff-0000-4000-8000-000000000002', sha256_hex: sha(calls.uploads.at(-1)) } }; },
    request: async (method, path) => {
      calls.gets.push(`${method} ${path}`);
      const hit = sources[path.slice(c.root.length)];
      if (hit instanceof Error) throw hit;
      if (!hit) throw httpError(404, 'not_found');
      return hit;
    },
  };
  return { c, calls };
}

const row = (type, id, extra = {}) => ({ [`/${ROUTES[type][0]}/${id}`]: { [ROUTES[type][1]]: { id, workspace_id: WS, channel_id: CH, title: 'Private title', ...extra } } });
const link = (type, id, channel_id) => [{ op: 'link', type, record_id: id, ...(channel_id ? { channel_id } : {}) }];
const savedLinks = calls => JSON.parse(calls.uploads.at(-1)).links;

test('each link type is checked against its own typed source route before anything is saved', async () => {
  for (const [type, [path]] of Object.entries(ROUTES)) {
    const { c, calls } = fakeTower({ sources: row(type, T(1)) });
    await editGoal(c, WS, GOAL_FILE, link(type, T(1), CH));
    expect(calls.gets).toEqual([`GET ${c.root}/${path}/${T(1)}`]);
    expect(savedLinks(calls)).toEqual([{ type, record_id: T(1), channel_id: CH }]);
    expect(calls.versions.length).toBe(1);
  }
});

test('a link without a channel is accepted when the record is readable in this workspace', async () => {
  const { c, calls } = fakeTower({ sources: row('task', T(1)) });
  await editGoal(c, WS, GOAL_FILE, link('task', T(1)));
  expect(savedLinks(calls)).toEqual([{ type: 'task', record_id: T(1) }]);
});

test('denied, missing, foreign, deleted and mismatched targets are refused with nothing uploaded or saved', async () => {
  const cases = {
    denied: { sources: { [`/tasks/${T(1)}`]: httpError(403, 'forbidden') }, channel: CH },
    missing: { sources: {}, channel: CH },
    otherWorkspace: { sources: row('task', T(1), { workspace_id: WS_OTHER }), channel: CH },
    wrongChannel: { sources: row('task', T(1), { channel_id: CH_OTHER }), channel: CH },
    otherRecordReturned: { sources: row('task', T(1), { id: T(2) }), channel: CH },
    deleted: { sources: row('task', T(1), { deleted_at: '2026-11-26T08:00:00.000Z' }), channel: CH },
    archivedDoc: { sources: row('doc', T(1), { archived_at: '2026-11-26T08:00:00.000Z' }), channel: CH, type: 'doc' },
  };
  for (const [name, k] of Object.entries(cases)) {
    const { c, calls } = fakeTower({ sources: k.sources });
    const error = await editGoal(c, WS, GOAL_FILE, link(k.type ?? 'task', T(1), k.channel)).then(() => null, e => e);
    expect(error?.message, name).toMatch(/Nothing was saved/);
    expect(calls.uploads.length, name).toBe(0);
    expect(calls.versions.length, name).toBe(0);
  }
});

test('a refusal reveals nothing about the source record', async () => {
  const { c } = fakeTower({ sources: row('task', T(1), { channel_id: CH_OTHER, title: 'Secret plan', description: 'Hidden detail' }) });
  const error = await editGoal(c, WS, GOAL_FILE, link('task', T(1), CH)).then(() => null, e => e);
  expect(error.message).not.toMatch(/Secret|Hidden|private|bbbbbbbb-0000-4000-8000-000000000002/i);
  // Same wording as a missing record, so existence is not an oracle.
  const missing = await editGoal(fakeTower().c, WS, GOAL_FILE, link('task', T(1), CH)).then(() => null, e => e);
  expect(missing.message).toBe(error.message);
});

test('a transport failure is reported as unverified, not as a refusal, and saves nothing', async () => {
  const { c, calls } = fakeTower({ sources: { [`/tasks/${T(1)}`]: httpError(503, 'unavailable') } });
  const error = await editGoal(c, WS, GOAL_FILE, link('task', T(1))).then(() => null, e => e);
  expect(error.message).toMatch(/Couldn't check/);
  expect(calls.uploads.length + calls.versions.length).toBe(0);
});

test('one bad link in a batch refuses the whole edit', async () => {
  const { c, calls } = fakeTower({ sources: row('task', T(1)) });
  const edits = [...link('task', T(1), CH), ...link('doc', T(2), CH)];
  await expect(editGoal(c, WS, GOAL_FILE, edits)).rejects.toThrow(/Nothing was saved/);
  expect(calls.uploads.length).toBe(0);
});

test('edits that add no link need no source lookups, and unlinking is never blocked by a denied source', async () => {
  const withLink = lib.encode(lib.applyEdit(lib.create({ name: 'Learn to sail', description: 'd' }), { op: 'link', type: 'task', record_id: T(1) }));
  const { c, calls } = fakeTower({ goalBytes: withLink });
  await editGoal(c, WS, GOAL_FILE, [{ op: 'set_name', expected: 'Learn to sail', value: 'Sail far' }]);
  await editGoal(c, WS, GOAL_FILE, [{ op: 'unlink', type: 'task', record_id: T(1) }]);
  expect(calls.gets).toEqual([]);
  expect(calls.versions.length).toBe(2);
});

test('an already linked record is not looked up again, so it stays editable after access is lost', async () => {
  const withLink = lib.encode(lib.applyEdit(lib.create({ name: 'Learn to sail', description: 'd' }), { op: 'link', type: 'task', record_id: T(1) }));
  const { c, calls } = fakeTower({ goalBytes: withLink });
  const r = await editGoal(c, WS, GOAL_FILE, [...link('task', T(1)), { op: 'set_name', expected: 'Learn to sail', value: 'Sail far' }]);
  expect(r.changed).toBe(true);
  expect(calls.gets).toEqual([]);
});

test('a lost race re-verifies only what is still being added, then saves against the new head', async () => {
  const { c, calls } = fakeTower({ sources: row('task', T(1)) });
  let first = true;
  const create = c.createVersion;
  c.createVersion = async (f, body) => { if (first) { first = false; throw httpError(409, 'stale_base_version'); } return create(f, body); };
  const r = await editGoal(c, WS, GOAL_FILE, link('task', T(1)));
  expect(r.changed).toBe(true);
  expect(calls.versions.length).toBe(1);
  expect(calls.uploads.length).toBe(2);
});
