#!/usr/bin/env bun
// Agent operations for Ambulando Goals over existing generic Tower contracts (channels, grants, Files). No keys held:
// requests are signed by the Autopilot capability broker (`wingman-capability.ts nip98`), as the artefact helpers do.
// Format and edit rules live in goals-lib.mjs and match the Android and Mac clients. See docs/goals.md.
import os from 'node:os';
import {nativeAgentCommand} from '../shared/goals-relational/agent-command.mjs';
import path from 'node:path';
import * as lib from './goals-lib.mjs';
import { editGoal, fileName, readGoal as readGoalFile } from './goals-ops.mjs';

const [command, ...rest] = process.argv.slice(2);
const options = {};
for (let i = 0; i < rest.length; i += 2) options[rest[i].replace(/^--/, '')] = rest[i + 1];
const need = (...names) => { for (const n of names) if (!options[n]) throw new Error(`--${n} is required`); };

async function client() {
  need('workspace');
  const sol = process.env.AMBULANDO_SOL || path.join(os.homedir(), 'code', 'ambulando', 'sol');
  const { brokerSigner, towerClient } = await import(path.join(sol, 'scripts', 'html-artifact', 'tower.mjs'));
  const c = towerClient({ baseUrl: options.tower || process.env.WINGMAN_TOWER_URL, workspaceId: options.workspace, sign: brokerSigner() });
  c.root = `/api/v4/flightdeck-pg/workspaces/${encodeURIComponent(options.workspace)}`;
  return c;
}

/** Every page of a list route; a full page without a cursor is an error, never "the rest is empty". */
async function listAll(c, pathname, key) {
  const rows = []; let cursor = null;
  for (let page = 0; page < 50; page++) {
    const sep = pathname.includes('?') ? '&' : '?';
    const body = await c.request('GET', `${pathname}${sep}limit=200${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
    const batch = body?.[key]; if (!Array.isArray(batch)) throw new Error(`Unexpected ${key} response`);
    rows.push(...batch); cursor = body.next_cursor;
    if (!cursor) { if (batch.length >= 200) throw new Error(`${key} list may be truncated`); return rows; }
  }
  throw new Error(`${key} list too long`);
}

async function findSpace(c, owner) {
  const scopes = (await listAll(c, `${c.root}/scopes`, 'scopes')).filter(s => s.kind !== 'dm' && !s.archived_at);
  const found = [];
  for (const scope of scopes) for (const ch of await listAll(c, `${c.root}/scopes/${scope.id}/channels`, 'channels')) if (lib.isOwnedChannel(ch, owner)) found.push(ch);
  found.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)) || a.id.localeCompare(b.id));
  const members = (await c.request('GET', `${c.root}/members`)).members.map(m => ({ actor_id: (m.actor.actor_id ?? m.actor.id)?.toLowerCase(), npub: m.actor.npub, kind: m.actor.kind, name: m.actor.display_name }));
  if (!found.length) return { state: 'needs_setup', scopes: scopes.map(s => ({ id: s.id, name: s.name })), members };
  const grants = (await c.request('GET', `${c.root}/channels/${found[0].id}/grants`)).grants;
  const verdict = lib.classifyGrants({ grants, members, owner });
  return verdict.safe ? { state: 'ready', channel: { id: found[0].id, name: found[0].name, scope_id: found[0].scope_id }, members } : { state: 'unsafe', reason: verdict.reason, channel_id: found[0].id };
}

const readGoal = readGoalFile;

const out = value => console.log(JSON.stringify(value, null, 2));
const summary = g => ({ name: g.name, status: g.status, target_date: g.target_date ?? null, checkpoints_reached: g.checkpoints.filter(c => c.reached).length, checkpoints: g.checkpoints.length, links: g.links.length });

try {
  if (['list','show','create','edit','move'].includes(command) && await nativeAgentCommand(await client(),options,command,out)) {
    // Native SQL authority handled the command; never fall through to historical File bytes.
  } else if (command === 'space') {
    need('owner'); out(await findSpace(await client(), options.owner));
  } else if (command === 'setup') {
    // Creates the owner's private Goals channel only when none exists. Grants are explicit: the owner manages; the creating
    // agent keeps contribute/manage access (an initial grant list replaces Tower's creator bundle); other agents contribute.
    need('owner', 'scope');
    const c = await client();
    const space = await findSpace(c, options.owner);
    if (space.state === 'ready') out({ ...space, created: false });
    else {
      if (space.state !== 'needs_setup') throw new Error(`Goals space is unusable: ${space.reason}`);
      const ownerActor = space.members.find(m => m.npub === options.owner)?.actor_id; if (!ownerActor) throw new Error('Owner is not a workspace member.');
      const me = await c.request('GET', `${c.root}/me`);
      const self = (me.actor_id ?? me.actor?.actor_id ?? me.actor?.id ?? me.membership?.actor_id)?.toLowerCase(); if (!self) throw new Error('Could not identify this agent.');
      const access = new Map([[ownerActor, 'manage']]);
      if (self !== ownerActor) access.set(self, options['self-access'] || 'manage');
      for (const id of (options.agents ? options.agents.split(',') : [])) if (!access.has(id.toLowerCase())) access.set(id.toLowerCase(), 'contribute');
      const body = { name: 'Goals', kind: 'channel', description: 'Private goals: visible only to the owner and agents they allow.',
        metadata: { system_key: lib.SYSTEM_KEY, goals: { schema_version: 1, owner_npub: options.owner } },
        grants: [...access].map(([principal_id, access_level]) => ({ principal_type: 'actor', principal_id, access_level })) };
      const { channel } = await c.request('POST', `${c.root}/scopes/${encodeURIComponent(options.scope)}/channels`, body);
      const verified = await findSpace(c, options.owner);
      if (verified.state !== 'ready' || verified.channel.id !== channel.id) throw new Error('Created channel did not verify as the owner’s private Goals space.');
      out({ ...verified, created: true });
    }
  } else if (command === 'list') {
    need('channel'); const c = await client();
    const files = (await listAll(c, `${c.root}/channels/${options.channel}/files`, 'files')).filter(lib.isGoalFile);
    const goals = [];
    const read = [], unreadable = [];
    for (const f of files) { try { const g = await readGoal(c, f.id); read.push({ id: f.id, versionId: g.versionId, goal: g.goal }); } catch (e) { unreadable.push({ file_id: f.id, unreadable: e.message }); } }
    // Focus order, as Home shows it; move a goal with set_focus_rank edits (docs/goals.md, "Focus order").
    out({ goals: [...lib.focusOrder(read).map(g => ({ file_id: g.id, version_id: g.versionId, focus_rank: lib.focusRank(g.goal), ...summary(g.goal) })), ...unreadable] });
  } else if (command === 'show') {
    need('file'); const g = await readGoal(await client(), options.file); out({ file_id: g.file.id, channel_id: g.file.channel_id, version_id: g.versionId, goal: g.goal });
  } else if (command === 'create') {
    need('channel', 'name', 'description'); const c = await client();
    const goal = lib.create({ name: options.name, description: options.description, start_date: options.start, target_date: options.target });
    const name = fileName(goal);
    const objectId = await c.uploadObject({ bytes: lib.encode(goal), contentType: lib.MIME, fileName: name });
    const { file } = await c.createFile(options.channel, { storage_object_id: objectId, display_name: name, metadata: { goal: { schema_version: lib.VERSION } } });
    const g = await readGoal(c, file.id);
    out({ file_id: file.id, version_id: g.versionId, goal: g.goal });
  } else if (command === 'edit') {
    // --ops is a JSON array of edits, each carrying the value it expects to replace, e.g.
    // [{"op":"set_reached","id":"a","expected":false,"reached":true},{"op":"link","type":"task","record_id":"<uuid>"}]
    need('file', 'ops'); const c = await client();
    const edits = JSON.parse(options.ops); if (!Array.isArray(edits) || !edits.length) throw new Error('--ops must be a non-empty JSON array');
    const result = await editGoal(c, options.workspace, options.file, edits);
    out({ file_id: options.file, version_id: result.versionId, changed: result.changed, goal: result.goal });
  } else if (command === 'move') {
    // Moves an active goal to --to (0 = top of Home) with the fewest set_focus_rank edits; each is expectation-checked,
    // so a concurrent reorder stops with a conflict (exit 3) and the earlier writes stay valid. Re-run `list` and retry.
    need('channel', 'file', 'to'); const c = await client();
    const files = (await listAll(c, `${c.root}/channels/${options.channel}/files`, 'files')).filter(lib.isGoalFile);
    const active = [];
    for (const f of files) { try { const g = await readGoal(c, f.id); if (g.goal.status === 'active') active.push({ id: f.id, goal: g.goal }); } catch { /* unreadable goals are not ordered */ } }
    const writes = lib.planMove(lib.focusOrder(active), options.file, Number(options.to));
    const saved = [];
    for (const w of writes) {
      try { await editGoal(c, options.workspace, w.id, [{ op: 'set_focus_rank', expected: w.expected, value: w.value }]); saved.push(w); }
      catch (e) { e.message = `Saved ${saved.length} of ${writes.length} order changes; stopped: ${e.message}`; throw e; }
    }
    out({ moved: options.file, writes });
  } else throw new Error('Usage: goals.mjs space|setup|list|show|create|edit|move --workspace <id> … (see docs/goals.md)');
} catch (error) {
  console.error(error.kind === 'conflict' ? `Conflict: ${error.message}` : error.message);
  process.exitCode = error.kind === 'conflict' || error.status === 409 ? 3 : 1;
}
