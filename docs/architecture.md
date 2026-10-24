# Ambulando native iPhone architecture

Ambulando for iPhone is a native SwiftUI client for the same Tower workspaces
used by the Ambulando (Flight Deck) web client in `../sol`. It is a separate
renderer, not a packaged WebView: navigation, chat, tasks, documents, files and
inbox are native screens drawing from a local database. It reuses the existing
Tower HTTPS + NIP-98 contracts. It adds no backend routes and changes no shared
schema.

This document records the source inventory (WP1) and the **target** native
architecture that later packages build on. Implementation status: WP2 delivers
the identity vault, signing, HTTPS transport, the SQLite store, the sync engine,
the descriptor → workspace → scope → channel read path, and the core storm
budget tests. Everything else described here, including chat, the outbox,
drafts, SSE, background refresh and UI hitch metrics, is target design for
WP3–WP6 until the parity matrix records evidence for it. The feature-by-feature status is in
[parity-matrix.md](parity-matrix.md); package order and acceptance are in
[work-packages.md](work-packages.md).

## 1. Source inventory

### 1.1 Ownership (Wingman Suite architecture board, v7)

The newest board version, v7, sets the responsibilities this client follows:

- **Tower** owns records, ACLs, storage and the NIP-98 API (`/api/v4/flightdeck-pg/...`).
- **Flight Deck/Ambulando** renders only from a local store. A single
  `TowerSyncService` is the sole network/update owner. It handles SSE with
  cursor recovery, fallback polling, initial hydration, targeted
  `ensureLoaded` requests, request coalescing/dedupe and materialisation
  transactions. The UI observes the store (Dexie `liveQuery`).
- **FIPS** is a WMapp native-shell capability (`window.fipsTransport` v2) and
  fails closed. There is no HTTPS/DNS/proxy fallback for a selected FIPS
  service, and the transport never signs.

The native mapping keeps the same rule: `SyncEngine` → SQLite → observation →
SwiftUI. Views never call the network.

### 1.2 Tower contract surface used by the web client

All routes are NIP-98 signed (`kind 27235`, tags `u`, `method` and, when there
is a body, `payload` = SHA-256 hex of the exact transmitted bytes). Workspace
routes carry `x-flightdeck-pg-app-npub` with the workspace's `app_npub`.

| Area | Routes (prefix `/api/v4/flightdeck-pg`) | Native package |
| --- | --- | --- |
| Service discovery (public) | `GET /.well-known/nstack.json` (origin root, schema `org.wingman.nstack.services` v1) | WP2 |
| Workspace discovery | `GET /workspaces` → `{identity, workspaces[{identity, label, slug, tower_base_url, membership, capabilities}]}` | WP2 |
| Workspace context | `GET /workspaces/:w/descriptor`, `GET /workspaces/:w/me`, `GET/PUT /me/scope-order`, pins | WP2/WP3 |
| Scopes and channels | `GET /workspaces/:w/scopes`, `GET /scopes/:s/channels`, `GET/PATCH /channels/:c` | WP2 (read), WP3 |
| Chat | `GET/POST /channels/:c/messages`, `GET /channels/:c/threads`, `GET/PATCH /threads/:t`, `PATCH/DELETE /messages/:m`, reactions | WP3 |
| Sync | `GET /workspaces/:w/sync` (snapshot/delta cursor, `has_more`, tombstones); `record-sync` priority/repair family; `GET /events/stream` (SSE) | WP3/WP5 |
| Tasks | `GET /channels/:c/tasks` (via sync bundles), `GET/PATCH /tasks/:t`, `POST /tasks/:t/state`, comments, assignments, relationships | WP4 |
| Documents | `GET/POST /channels/:c/docs`, `GET /docs/:d`, `GET /docs/:d/body`, `PATCH /docs/:d`, edit leases, comments, versions | WP4 |
| Files | `GET/POST /channels/:c/files`, folders, versions, `GET /files/:f/object`, `/storage/prepare`, `/api/v4/storage/:id[/content|/complete]` | WP4 |
| Inbox inputs | `resource-view-states`, `message-activity`, task `attention`, mentions | WP4 |
| Notifications | `notifications/subscriptions` — Web Push (VAPID) only | Not native (see §6) |

Serializer shapes were read from Tower `src/services/flightdeck-pg-api.ts`
(`serializeFlightDeckPgScope/Channel/Message/Task/Doc/File/WorkspaceSummary`).
Every record carries `workspace_id`, `row_version`, `created_at` and `updated_at`.
Messages also carry `thread_id`, `client_request_id`, `attachments` and
`record_state`.

### 1.3 Signing and consent semantics retained

- **NIP-98**: a fresh event per request, an exact URL, an uppercase method, and a
  payload hash computed over the same `Data` that is sent. This matches
  `sol/src/auth/nostr.js` `buildHttpAuthEvent`.
- **Chat instruction signature**: `kind 33358`, with tags
  `["protocol","flightdeck_pg_message_instruction"]`, `["body_sha256",hex]`,
  `["workspace_id",w]`, `["channel_id",c]`, optional `["thread_id",t]`, and for
  edits `["message_id",m]` and `["revision",n]`. It is wrapped as
  `message_signature {version:1, signer_npub, body_sha256, nostr_event}`. This
  matches `sol/src/message-instruction-signatures.js` and the shipped native
  NoteToSelf app.
- The user explicitly imports their identity into this app. The app never
  searches for, reads or exports keys held by other apps or the browser. A
  per-install Keychain secret (`WhenUnlockedThisDeviceOnly`, non-synchronizable)
  combined with a PIN (PBKDF2-HMAC-SHA256, 210,000 iterations) seals the scalar
  with AES-GCM. Only the sealed envelope is written to disk.

### 1.4 Theme

The tokens come from `sol/src/ambulando-tokens.css` ("perspective passage"),
with light and dark palettes, a deep-purple primary (`#2B1B3C` light /
`#CBB8FF` dark), navy foreground, `#F6F6FA` background, a 10 pt panel radius and
a 44 pt touch target. Brand artwork is the approved `passage-master.png`. The
app icon is a proportional resample on its original white backing; no geometry
is redrawn. Icons map Lucide names to the closest SF Symbols. These are native
symbols, not byte-identical Lucide glyphs.

### 1.5 Native reference

`sol/native/NoteToSelf` is the reference for identity vault, NIP-98, kind 33358
and idempotent send handling. It pins `21-DOT-DEV/swift-secp256k1` 0.23.2, and
this client uses the same pin and patterns. Because it has its own bundle id
(`studio.otherstuff.ambulando.native`) and Keychain service, it cannot read
NoteToSelf's identity, and vice versa.

## 2. Process and module layout

```
Ambulando.xcodeproj         iPhone app target (SwiftUI), bundle studio.otherstuff.ambulando.native
Ambulando/                  App: scenes, view models (MainActor), theme, assets
AmbulandoCore/              Swift package, UI-free, tested with `swift test` and on simulator
  Crypto/                   Bech32, nsec validation, IdentityVault, Signer actor, NIP-98, kind 33358
  Transport/                TowerClient (HTTPS-only, redirect refusal, exact-body signing), nStack descriptor
  Store/                    SQLite (WAL) writer actor + read pool, migrations, record tables, outbox
  Sync/                     SyncEngine actor: bounded job queue, cancellation, backoff, change coalescer
  Perf/                     Signposts and main-thread responsiveness probe
```

## 3. Threading model

| Work | Executes on | Never on main |
| --- | --- | --- |
| HTTP, TLS, JSON decode | `TowerClient` actor + URLSession delegate queue | ✓ |
| Schnorr signing, PBKDF2 | `Signer` actor (detached, user-initiated priority) | ✓ |
| SQLite writes | `LocalStore` writer actor, one serialized connection, batched transactions | ✓ |
| SQLite reads for screens | `LocalStore` read connection (separate actor, WAL snapshot isolation) | ✓ |
| Change fan-out | `ChangeCoalescer` — merges table/workspace keys, emits ≤ 10 Hz | ✓ |
| View state | `@MainActor @Observable` view models assign finished value snapshots | main (assign only) |

The main actor does only three things: assign a value snapshot, run SwiftUI
layout, and handle input. A view model reacts to a coalesced change by
re-querying off-main, then hops to main with a plain `Sendable` struct array.
Rows are value types with stable `id`s, so `List`/`ForEach` diffs incrementally
and keeps scroll position. Drafts live in the database (WP3) and are written on
debounce, never while a key is being processed.

## 4. Persistence and isolation

- There is one SQLite database per app install, in
  `Application Support/AmbulandoNative/`. Its directory is excluded from backup
  and uses file protection `completeUntilFirstUserAuthentication`, so
  background refresh can read it after the first unlock.
- Every record row has the primary key `(workspace_id, id)`. Every query is
  workspace-scoped, and removing a workspace deletes only its rows. Connection
  records bind `origin`, `workspace_id`, `app_npub` and `signer_npub`, so a
  different unlocked identity cannot write under another identity's connection.
- Each table stores the canonical Tower JSON (`raw`) beside the indexed columns.
  New fields survive unknown-field round trips and later migrations.
- Upserts are guarded by `row_version`: an older version never overwrites a
  newer one. This keeps snapshot/delta races idempotent.
- The outbox (WP3) holds frozen signed-request inputs with
  `client_request_id`. Tower idempotency keeps retries safe; outcome handling
  follows NoteToSelf (`idempotency_conflict`, `thread_not_found`,
  `channel_not_found`).

## 5. Sync engine and responsiveness budgets

`SyncEngine` is the only owner of network refresh. Jobs are keyed (for example
`discover`, `scopes:<w>`, `channels:<w>:<s>` and later `messages:<w>:<c>`). A
duplicate key coalesces into the in-flight job. Concurrency is bounded (default
3), every job is cancellable, and failures back off exponentially with jitter
(2 s → 5 min). Visible-screen jobs run at higher priority than catch-up. Writes
are applied in batches of at most 500 rows per transaction, so readers are never
starved.

Measurable budgets, enforced by tests (WP2 for the core and WP5 for the UI):

| Budget | Target | Evidence |
| --- | --- | --- |
| Main-actor job latency during sync storm (20k rows) | p99 ≤ 16 ms, max ≤ 50 ms | `SyncStormTests` heartbeat probe |
| Screen read latency during storm (reader vs. writer) | p95 ≤ 25 ms | `SyncStormTests` |
| Coalesced UI change notifications | ≤ 10 per second per observer | `ChangeCoalescerTests` |
| Keystroke-to-render (composer) | p95 ≤ 16.7 ms at 60 Hz, no dropped characters | WP5 XCUITest + `os_signpost` |
| Hitch ratio while scrolling chat under storm | < 5 ms/s (Apple "good") | WP5 XCTOSSignpostMetric/hitch metrics |
| Cold launch to cached workspace list | ≤ 400 ms after first frame | WP5 XCTApplicationLaunchMetric |

Zero shared-resource impact cannot be guaranteed. CPU, memory bandwidth and
SQLite WAL checkpoints are shared, so these targets are measured, not assumed.

## 6. Platform limits (honest scope)

- **Background execution**: iOS suspends apps. WP5 uses `BGAppRefreshTask`
  (opportunistic, a short window, with an expiration handler that cancels the
  sync jobs) and a background `URLSession` for large uploads and downloads.
  There is no indefinite background SSE and no fake audio/location modes. SSE
  runs only while the app is in the foreground and resumes from the stored
  cursor.
- **Parallelism**: Swift concurrency within one process. There is no claim of
  arbitrary parallel OS processes.
- **Push**: Tower implements Web Push (VAPID) only, in
  `flightdeck-pg-notifications.ts`. APNs needs a separate, evidenced server
  capability and is not in scope.
- **Transport**: HTTPS only. The live `sb4` descriptor advertises Tower
  `https`/`nip-98` and no FIPS service. FIPS is a WMapp-shell capability, so
  native-ip does not offer it. If a FIPS-only endpoint is selected, the app
  refuses it rather than falling back to HTTPS.
- **Web content**: only records that are themselves HTML documents, such as
  HTML artefacts and WApps' own UIs, open in an explicitly labelled web view, and
  they are not counted as native parity. Canvas, naplets, Excalidraw, the context
  tree, agents and the pipeline viewer are *proposed later native packages*,
  not exclusions. Their scope awaits Pete's prioritisation.
