// Regenerates tower-navigation.json from Tower's own Flight Deck PG serializers, so the native workspace → scope →
// channel read path is tested against the bodies Tower actually returns (not a sample written to agree with the client).
// Usage: bun generate-tower-navigation.ts <path-to-tower> > tower-navigation.json
//
// Envelopes follow tower/src/routes/flightdeck-pg.ts:
// - GET /workspaces: { identity: buildFlightDeckPgIdentity(null, app), workspaces: [summary], next_cursor: null }
// - GET /workspaces/:w/scopes: { identity, scopes: [scope + can_manage], next_cursor: null }
// - GET /workspaces/:w/scopes/:s/channels: { identity, scope_id, channels: [channel], next_cursor: null }
// Rows are synthetic; every key is the public NIP-19 specification test key, never a real identity.
import { join } from 'node:path';

const tower = process.argv[2];
if (!tower) throw new Error('usage: bun generate-tower-navigation.ts <path-to-tower>');
const api = await import(join(tower, 'src/services/flightdeck-pg-api.ts'));

const npub = 'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
const at = (s: string) => new Date(s);
const workspace = (id: string, name: string, slug: string) => ({
  id, name, slug, description: null, avatar_url: null, metadata: {}, v4_workspace_id: null,
  app_npub: npub, tower_service_npub: npub, workspace_service_npub: npub, workspace_owner_npub: npub,
  created_at: at('2026-09-01T10:00:00.000Z'), updated_at: at('2026-10-20T10:00:00.000Z'),
});
const scope = (id: string, w: string, name: string, kind: string, defaultChannel: string | null) => ({
  id, workspace_id: w, name, description: null, kind, owner_actor_id: null, owner_group_id: null,
  default_channel_id: defaultChannel, created_at: at('2026-09-02T10:00:00.000Z'), updated_at: at('2026-10-21T10:00:00.000Z'),
});
const channel = (id: string, w: string, s: string, name: string, position: string | null, extra: Record<string, unknown> = {}) => ({
  id, workspace_id: w, scope_id: s, name, description: null, metadata: null, kind: 'channel', position,
  participant_npubs: null, created_at: at('2026-09-03T10:00:00.000Z'), updated_at: at('2026-10-22T10:00:00.000Z'), ...extra,
});

const W1 = '2e5caefd-0000-4000-8000-0000000000a1';
const W2 = '2e5caefd-0000-4000-8000-0000000000a2';
const S1 = '76d518f7-0000-4000-8000-0000000000b1';
const S2 = '76d518f7-0000-4000-8000-0000000000b2';
const DM = '76d518f7-0000-4000-8000-0000000000b3';
const S3 = '76d518f7-0000-4000-8000-0000000000b4';
const C1 = '0617d526-0000-4000-8000-0000000000c1';
const C2 = '0617d526-0000-4000-8000-0000000000c2';
const C3 = '0617d526-0000-4000-8000-0000000000c3';
const C4 = '0617d526-0000-4000-8000-0000000000c4';
const C5 = '0617d526-0000-4000-8000-0000000000c5';

const workspaces = [workspace(W1, 'Wingman', 'wingman'), workspace(W2, 'Other Stuff', 'other-stuff')];
const scopes: Record<string, ReturnType<typeof scope>[]> = {
  [W1]: [scope(S1, W1, 'Ambulando', 'project', C1), scope(S2, W1, 'Operations', 'team', null), scope(DM, W1, 'DMs', 'dm', null)],
  [W2]: [scope(S3, W2, 'Studio', 'project', null)],
};
const channels: Record<string, ReturnType<typeof channel>[]> = {
  [S1]: [channel(C1, W1, S1, 'general', '1'), channel(C2, W1, S1, 'native app', null)],
  [S2]: [],
  [DM]: [channel(C3, W1, DM, 'DM: pair', null, { kind: 'dm', participant_npubs: [npub] })],
  [S3]: [channel(C4, W2, S3, 'studio', '2'), channel(C5, W2, S3, 'ideas', '1')],
};

const identity = (w: ReturnType<typeof workspace> | null) => api.buildFlightDeckPgIdentity(w, npub);
const out = {
  generated_from: 'tower/src/services/flightdeck-pg-api.ts serializers; envelopes per tower/src/routes/flightdeck-pg.ts',
  workspaces: {
    identity: identity(null),
    workspaces: workspaces.map((w) => api.serializeFlightDeckPgWorkspaceSummary(
      { workspace: w, membership: { role: 'member', created_at: at('2026-09-05T10:00:00.000Z') } },
      { towerBaseUrl: 'https://tower.example' },
    )),
    next_cursor: null,
  },
  scopes: Object.fromEntries(workspaces.map((w) => [w.id, {
    identity: identity(w),
    scopes: scopes[w.id].map((s) => ({ ...api.serializeFlightDeckPgScope(s), can_manage: false })),
    next_cursor: null,
  }])),
  channels: Object.fromEntries(Object.values(scopes).flat().map((s) => [s.id, {
    identity: identity(workspaces.find((w) => w.id === s.workspace_id) ?? null),
    scope_id: s.id,
    channels: channels[s.id].map(api.serializeFlightDeckPgChannel),
    next_cursor: null,
  }])),
};
console.log(JSON.stringify(out, null, 2));
