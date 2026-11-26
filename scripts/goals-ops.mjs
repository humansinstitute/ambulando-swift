// Goal file operations over a Tower client (the seam: `getFile`, `listVersions`, `readVersionBytes`, `uploadObject`,
// `createVersion`, `request`, `root`). goals.mjs wires the broker-signed client; tests wire a fake one.
import { createHash } from 'node:crypto';
import * as lib from './goals-lib.mjs';

export const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export const fileName = goal => `${goal.name.replace(/[\u0000-\u001f\u007f/\\]/g, ' ').trim().slice(0, 80) || 'Goal'}.goal.json`;

/** A link target the caller may not (or cannot) link. The message never carries anything read from the source record. */
export class LinkRefused extends Error {}

export async function readGoal(c, fileId) {
  const { file } = await c.getFile(fileId);
  if (!lib.isGoalFile(file)) throw new Error('This file is not a goal.');
  // Tower returns the current version as an id (the embedded `current_version` is null on a File read), so read the
  // version list for the head and its hash, then fetch exactly that version's bytes.
  const history = await c.listVersions(fileId);
  const versionId = history.current_version_id ?? file.current_version_id;
  const version = history.versions?.find(v => v.id === versionId);
  if (!versionId || !version) throw new Error('Goal has no current version.');
  if (version.size_bytes > lib.MAX_BYTES) throw new Error('This goal is too large to read.');
  const bytes = await c.readVersionBytes(fileId, versionId);
  if (version.sha256_hex && version.sha256_hex.toLowerCase() !== sha(bytes)) throw new Error('Goal digest mismatch.');
  return { file, versionId, goal: lib.parse(bytes) };
}

// Each link type is verified against the source record's own typed route, as the signing identity.
const SOURCES = { chat: { path: 'threads', key: 'thread' }, task: { path: 'tasks', key: 'task' }, doc: { path: 'docs', key: 'doc' }, file: { path: 'files', key: 'file' } };

const lower = v => (typeof v === 'string' ? v.toLowerCase() : null);
const gone = row => row.deleted_at != null || row.record_state === 'deleted' || row.record_state === 'archived' || row.archived_at != null;

/**
 * Refuses (before anything is uploaded) a link whose target this identity cannot read, that does not exist, that lives
 * in another workspace, or whose supplied channel is not the record's authoritative channel. Denied, missing and foreign
 * targets get the same message so the refusal says nothing about the record.
 */
export async function verifyLinkTarget(c, workspaceId, link) {
  const source = SOURCES[link.type];
  const refuse = () => new LinkRefused(`Can't link ${link.type} ${link.record_id}: it isn't available to this agent in this workspace${link.channel_id ? ' and channel' : ''}. Nothing was saved.`);
  if (!source) throw refuse();
  let body;
  try { body = await c.request('GET', `${c.root}/${source.path}/${encodeURIComponent(link.record_id)}`); }
  catch (e) {
    if ([400, 403, 404, 410].includes(e.status)) throw refuse();
    throw new Error(`Couldn't check the ${link.type} link target (${e.status ?? 'network error'}). Nothing was saved; try again.`);
  }
  const row = body?.[source.key];
  if (!row || typeof row !== 'object' || lower(row.id) !== link.record_id || lower(row.workspace_id) !== lower(workspaceId)
    || !lower(row.channel_id) || gone(row) || (link.channel_id && lower(row.channel_id) !== link.channel_id)) throw refuse();
}

/** Links present in `after` that `before` did not have. */
export const addedLinks = (before, after) => after.links.filter(l => !before.links.some(b => b.type === l.type && b.record_id === l.record_id));

/** Applies `edits` to the goal file with the compare-and-swap loop; every newly linked target is verified before each upload. */
export async function editGoal(c, workspaceId, fileId, edits) {
  let seen = null;
  const store = {
    read: async () => { const g = await readGoal(c, fileId); seen = g.goal; return { versionId: g.versionId, goal: g.goal }; },
    save: async (base, bytes) => {
      const next = lib.parse(bytes);
      for (const link of addedLinks(seen, next)) await verifyLinkTarget(c, workspaceId, link);
      const objectId = await c.uploadObject({ bytes, contentType: lib.MIME, fileName: fileName(next) });
      try {
        const r = await c.createVersion(fileId, { base_version_id: base, storage_object_id: objectId, client_mutation_id: crypto.randomUUID() });
        const recorded = r?.version?.sha256_hex; if (recorded && recorded.toLowerCase() !== sha(bytes)) throw new Error('Saved goal did not match what was sent; reload to check.');
        return { saved: r.version.id };
      } catch (e) { if (e.status === 409 && String(e.code).includes('stale')) return { conflict: true }; throw e; }
    },
  };
  return lib.editWithRetry(store, edits);
}
