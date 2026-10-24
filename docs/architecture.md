# Ambulando native iPhone architecture

Ambulando for iPhone is a native SwiftUI client for the same Tower workspaces
used by the Ambulando (Flight Deck) web client in `../sol`. It is a separate
renderer, not a packaged WebView: navigation, chat, tasks, documents, files and
inbox are native screens drawing from a local database. It reuses the existing
Tower HTTPS + NIP-98 contracts. It adds no backend routes and changes no shared
schema.

This document records the source inventory (WP1) and the **target** native
architecture that later packages build on. Implementation status:

- WP2 delivered the identity vault, signing, HTTPS transport, the SQLite store, the sync engine, the
  descriptor → workspace → scope → channel read path, and the core storm budget tests.
- WP3 (0.1.0 build 2) delivers native chat, the durable outbox, drafts, mentions, scope order and
  collapse, and chat path restoration (§4.1, §5.1).
- WP4 (0.1.0 build 3) delivers native inbox, tasks, documents, files, search, message reactions/edit/delete and chat
  photo attachments, on schema v3 with a durable write queue (§4.2–§4.4).
- SSE, background refresh, and device UI hitch metrics remain target design for WP5–WP6, as does
  anything else here without evidence in the parity matrix.

The feature-by-feature status is in [parity-matrix.md](parity-matrix.md); package order and
acceptance are in [work-packages.md](work-packages.md).

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
- The outbox holds unsent chat messages (see §4.1).

### 4.1 Chat outbox and drafts (WP3, delivered)

Contract read from Tower `POST /workspaces/:w/channels/:c/messages` and
`flightdeck-pg-message-signatures.ts`:

- Tower trims `body`, and the kind 33358 `content` must equal the trimmed body.
- The event's `workspace_id` and `channel_id` tags must match, plus `thread_id` for replies.
- `client_request_id` replay hashes channel, thread, `create_thread`, body and attachments. It does
  not hash the signature. A replay returns `200 {replayed: true}`; a different message under the same
  id returns `409 idempotency_conflict`.
- A new conversation is `create_thread: true`, as in the web client. A reply is `thread_id`.
- Ordinary NIP-98 verification accepts events within 300 s of `created_at` and does not consume
  event ids.

Native behaviour:

- **Durable composing.**
  - A draft is keyed by connection, workspace, channel and thread, and written on a 350 ms debounce
    through the store writer.
  - Sending inserts the outbox row and deletes the draft in one transaction.
  - Every row records `connection_id`, `origin`, `signer_npub`, `workspace_id` and `app_npub`. The
    request is built only from the row. The composer captures its own target, never the current
    selection, so a workspace switch or lock cannot redirect a message.
- **Signing.**
  - The body is signed (kind 33358) only while the bound identity is unlocked. Rows written while
    locked wait in `awaiting_signature` until an explicit unlock.
  - The exact JSON bytes are frozen once (`request IS NULL` guard) and resent unchanged on every
    attempt, with a freshly signed NIP-98 header each time.
- **States.**
  - `queued` → `sending` → acknowledged: the row is deleted in the same transaction that stores
    Tower's message and thread.
  - `retrying` (automatic backoff): network errors, 408/425/429/5xx, the first two 401s, or an
    unreadable 2xx.
  - `failed` (the user can Retry, Edit or Discard): 403, 404 `thread_not_found` or
    `channel_not_found`, 409 `idempotency_conflict`, validation errors.
  - A retryable failure holds later messages of the same conversation, so order is kept.
  - A synced copy carrying the row's `client_request_id` from the same signer also retires it,
    so nothing is shown twice.
- **Relaunch.** `sending` rows become `queued` at launch; Tower's replay makes the resend safe.
- **Disconnect.** Disconnecting deletes the connection's drafts and outbox (cascade) after a warning
  that counts unsent messages.


### 4.2 Durable writes (WP4, delivered)

Every non-chat mutation is a `writes` row bound to connection, origin, signer, workspace and `app_npub`, sent by
`WriteSender` through the sync engine at `user` priority (the reserved slot). Writes to one record run in order; a
retryable failure holds only that record's later writes.

| Write | Route | Replay / conflict rule |
| --- | --- | --- |
| Task create | `POST /channels/:c/tasks` | `client_request_id` = row id (Tower replays) |
| Task state | `POST /tasks/:t/state` | Set-style, idempotent |
| Task title/description/priority | `PATCH /tasks/:t` | Tower does not check `row_version` here, so the task is re-read first; a field changed by someone else since the edit began becomes `conflict` (user: Apply mine / Discard) |
| Task assignee | `PATCH /tasks/:t` with `assigned_to_npub`, `row_version` | 409 → re-read; retry only if the assignee is still what the user saw |
| Task / doc comment | `POST …/comments` | `metadata.client_record_id`; after an ambiguous attempt the list is read before resending |
| Doc comment status | `PATCH /docs/:d/comments/:c` | `row_version`, re-read on 409 |
| Message edit | `PATCH /messages/:m` | kind 33358 with `message_id`, `revision`; frozen once; 409 → conflict unless Tower already has the text |
| Message delete | `DELETE /messages/:m?row_version=` | 404 or already deleted counts as done |
| Reaction add / remove | `POST/DELETE /reactions` | Add reconciled by author + emoji |
| Read position | `PUT /resource-view-states/:t/:id`, `POST …/mark-viewed` | Monotonic; applied locally first (local read position is never lowered by a sync) |
| File upload, doc create | storage prepare → upload → complete → `POST …/files` or `…/docs` | Prepared object id persisted and reused; reconciled by storage object id |

An attempt interrupted mid-request (lock, relaunch, network loss) is flagged ambiguous and reconciled before resend.

### 4.3 Document bodies and saves (WP4, delivered)

- `GET /docs/:d/body` bytes are verified against Tower's sha256 and cached with the document row version.
- `DocumentBody` decodes the `document_content_v1` envelope, legacy models and raw Markdown, and re-encodes in the
  same representation. JSON is handled by a lossless parser (key order and number lexemes preserved).
- ProseMirror `editor_state` is authoritative: edits change only touched text blocks (mark-preserving diff); the
  derived Markdown `content` and `content_blocks` come from a port of sol's `prosemirror-to-flightdeck.js`, checked
  byte-for-byte against output generated from sol (`Tests/…/Fixtures/generate-prosemirror-golden.mjs`).
- Saving: the draft is written to SQLite first; `DocumentSaver` acquires (and the editor renews every 60 s) the edit
  lease, uploads a new storage object, and `PATCH`es with base `row_version`, base body sha256 and lease token. A stale
  base yields Tower's recovery copy (409 `document_recovery_created`) and keeps the draft; nothing overwrites the head.

### 4.4 Storage transfers (WP4, delivered)

A presigned upload URL on another HTTPS host receives an unsigned `PUT` (no Authorization, no cookies, redirects
refused). Tower's own fallback URL is accepted only as the exact `/api/v4/storage/:id` path on the pinned origin and is
sent signed (≤ 8 MB). Anything else is refused. Downloads use the typed object route (base64 + sha256) and land in a
content-addressed cache under Caches; chat attachments use the signed storage content route on the pinned origin.

## 5. Sync engine and responsiveness budgets

`SyncEngine` is the only owner of network refresh. Jobs are keyed (for example
`discover`, `scopes:<w>`, `channels:<w>:<s>` and later `messages:<w>:<c>`). A
duplicate key coalesces into the in-flight job. Concurrency is bounded (default
3), every job is cancellable, and failures back off exponentially with jitter
(2 s → 5 min). Visible-screen jobs run at higher priority than catch-up. Writes
are applied in batches of at most 500 rows per transaction, so readers are never
starved.

Priorities are `user` (a send, opening a thread), then `visible` (the open channel), then
`background` (catch-up). One engine slot is reserved for non-background work, so a send never waits
behind a storm of catch-up jobs. A delayed (retry) request never postpones an immediate one.

### 5.1 Chat catch-up (WP3, delivered)

`GET /channels/:c/messages` is the only message list route. It pages forward from the oldest message
(`created_at ASC, id ASC`, opaque cursor, at most 200 per page), excludes deleted rows and has no
"newest first" mode. `/sync` deltas re-send whole channel bundles, including tasks and docs. So
WP3 uses the messages route:

- Each channel stores the cursor that fetched its last page (`channel_sync`). An incremental catch-up
  re-reads from there to the end, at least one page. It then removes local rows Tower no longer lists,
  but only inside the range it actually covered. Rows newer than the last fetched row, such as a send
  acknowledged mid-catch-up, are never touched.
- Progress is saved after each page, so an interrupted catch-up resumes.
- Pull to refresh re-reads the whole channel and reconciles it.
- Opening a thread fetches `?thread_id=` at user priority. Thread titles come from `/threads` (one
  page, never used for deletion).
- Directory (`/members`) and scope order (`/me/scope-order`) refresh with the workspace.
- A page with rows from another channel or workspace is refused, and a cancelled catch-up never
  reconciles.

Known gap: edits or deletions older than the last page appear after a full refresh until
foreground SSE / `/sync` deltas (WP5).

Measurable budgets, enforced by tests (WP2 for the core and WP5 for the UI):

| Budget | Target | Evidence |
| --- | --- | --- |
| Main-actor job latency during sync storm (20k rows) | p99 ≤ 16 ms, max ≤ 50 ms | `SyncStormTests` heartbeat probe |
| Screen read latency during storm (reader vs. writer) | p95 ≤ 25 ms | `SyncStormTests` |
| Coalesced UI change notifications | ≤ 10 per second per observer | `ChangeCoalescerTests` |
| Typing in the chat composer during a 20k-row storm (simulator, sample data) | no dropped characters; main-actor p99 ≤ 16 ms | WP3 `ChatFlowUITests.testTypingDuringSyncStorm`, with a no-write control run. Result: p99 4.7–10.6 ms. **Max target ≤ 50 ms not met**: 53–60 ms, comparable to the no-write control (53–70 ms), so it is attributed to keyboard/UI work, not proven sync-free. Carried to WP5 device profiling; the test's 100 ms bound is a freeze guard only |
| Keystroke-to-render (composer) | p95 ≤ 16.7 ms at 60 Hz, no dropped characters | WP5 XCUITest + `os_signpost` (device) |
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
