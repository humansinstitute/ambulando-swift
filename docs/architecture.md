# Ambulando native iPhone architecture

Ambulando for iPhone is a native SwiftUI client for the same Tower workspaces
used by the Ambulando (Flight Deck) web client in `../sol`. It is a separate
renderer, not a packaged WebView: navigation, chat, tasks, documents, files and
inbox are native screens drawing from a local database. It reuses the existing
Tower HTTPS + NIP-98 contracts. It adds no backend routes and changes no shared
schema. Its only other network peers, as in the web client, are sol's public Nostr relays (read-only kind-0 profile
queries) and the hosts named in those profiles' pictures (§4.8); both can be turned off in Settings.

This document records the source inventory (WP1) and the **target** native
architecture that later packages build on. Implementation status:

- WP2 delivered the identity vault, signing, HTTPS transport, the SQLite store, the sync engine, the
  descriptor → workspace → scope → channel read path, and the core storm budget tests.
- WP3 (0.1.0 build 2) delivers native chat, the durable outbox, drafts, mentions, scope order and
  collapse, and chat path restoration (§4.1, §5.1).
- WP4 (0.1.0 build 3) delivers native inbox, tasks, documents, files, search, message reactions/edit/delete and chat
  photo attachments, on schema v3 with a durable write queue (§4.2–§4.4).
- WP5 (0.1.0 build 4) delivers foreground live updates (SSE plus a durable event cursor), the background refresh
  pipeline, background transfers for presigned object-store URLs, the opt-in read credential, and the
  responsiveness work in §5.2 (§5.1–§5.3, §6).
- Build 7 (task 6b035d34) delivers the Context Tree outline, Canvas boards with native Excalidraw rendering, agents and
  activity, the Toolbox with a labelled web view, and personal pins, on schema v4 (§4.6).
- Build 10 applies the web's white surfaces and purple highlights (§1.4), caches public Nostr names and avatars on
  schema v5 and adds chat separators (§4.8).
- Build 11 adds explicit Paste of images and files into channel and thread composers as workspace storage links
  (§4.1, "Pasted images and files"). No schema change.
- Build 12 names people from their public Nostr profile first, as the web does, loads Blossom avatars through checked
  redirects (≤ 5 MiB), and adds the full-screen in-app browser with native NIP-07 signing (§4.9). No schema change; new
  `app_state` key `browser.sites.v1` and a separate browser website data store.
- Build 13 opens WApps (Deck › Hello and Links › Apps, Toolbox) and Context Tree artifact links as signed in-app
  browser tabs through `BrowserModel.launch` (§4.9); HTML naplets keep the sandboxed view. No schema change.
- Build 15 puts all browser chrome in one compact bottom bar (Ambulando, back, forward, address, tabs, ••• menu) on
  iPhone, iPad and Mac (§4.9). No schema change.
- Device validation and packaging are WP6, as is anything else here without evidence in the parity matrix.

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
| Context Tree | `GET /scopes/:s/context/components`, `…/components/:c/references` (`routes/context-tree.ts`) | build 7 |
| Canvas | `GET /canvases`, `GET /canvases/:c/snapshot`, `GET /canvases/:c/naplets/:n/html`, `GET /files/:f/versions/:v/object` | build 7 |
| Agents | `GET /workspace-agents`, `GET /agent-activities?channel_id=` | build 7 |
| Toolbox | `GET /personal-wapps` | build 7 |
| Personal pins | `GET /record-sync/priority?family=personal_pin`, `PUT /me/pins/:type/:id` | build 7 |
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

Build 10 applies the tokens the way `sol/src/styles.css` does, not only their values. The web paints `body`, the
header, the chat feed, the sidebar and the mobile section bar with `--card` (`#FFFFFF` / dark `#1A2238`); `--background`
(`#F6F6FA` / `#10162B`) appears only behind a few inputs and nested cards. Natively `Amb.background` is therefore the
card colour, and `Amb.canvas` the old background, used behind grouped forms (Settings, Search, file details) whose rows
are drawn on `Amb.card`. Highlights follow the web's two patterns: a selected row is `--muted` with bold `--primary` text
(`.sidebar-scope-channel-row.active`, `.reaction-pill-active`, Deck filters); an active tab or a fallback avatar is solid
`--primary` with `--primary-foreground` (`.chat-channel-tab-item.active` → segmented controls via `UIAppearance`,
`.identity-card-avatar-fallback`). The pale `--accent` stays for mention chips and task chips.

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

**Pasted images and files (build 11).** Sources: sol `handleMentionComposerPaste`, `handleChatPaste`,
`uploadChatFileDraft`, `createStorageMarkdown` / `createStorageFileMarkdown`, `chat-attachments.js`.

- **Paste entry.** The composer field is a `UITextView` wrapper (`ComposerTextView`) because SwiftUI's field has no
  hook for an image or file paste. Only `paste(_:)` is overridden; `canPerformAction` reads only the pasteboard's
  has-flags. Images, or items carrying no text, go to `ComposerUploads.paste`. Anything else (and an empty result)
  is `super.paste`. A copied file counts as a file when it carries a name or a file URL.
- **Placeholders.** One token per item (`[ Uploading image|file <uuid>... ]`), at most 4 per paste, inserted with
  `insertText` so the caret, undo and the draft debounce behave like typing. Text changed from outside the keyboard
  (mentions, results, drafts) keeps the caret through `ComposerText.remap`. SwiftUI can run `updateUIView` inside a
  keystroke, re-entrantly while the composer's `@Observable` text is changing and still returns the previous value,
  or before `textViewDidChange`. The coordinator therefore writes text back only when it differs from what the view
  last reported, and never while it is reporting. Without this, the second typed character was dropped under the
  typing and draft UI tests.
- **Staging.** Off the main actor: images go through `ImagePrivacy.strippedPNG`; files are copied inside the
  provider's handler (≤ 100 MB, the Files limit). Bytes and a JSON record (target, `app_npub`, kind, name, type,
  size, sha256, prepared object, and object id once done) sit in Staging as `paste-<id>.*`.
- **Upload.** `ComposerUploads` (one per app, main actor) runs one upload at a time. `ComposerUploadTransfer` uses
  `SyncEngine.perform` at `user` priority with `TowerAPI.store`: prepare → upload (presigned PUT unsigned, background
  transfers) → complete, verified. The prepared object is reused on Retry. Signing is done only by the connection the
  paste was captured in, and only while it is unlocked; otherwise the upload fails with "Unlock to upload".
  `perform` hands the job's error to its caller (no key backoff), and a job dropped by `cancel` or `cancelAll` ends
  with `CancellationError` ("Upload was interrupted.", retryable).
- **Results.** The token is unique, so its Markdown can only replace it in the captured target's text:
  - the live composer of that target (`UploadTokenHost`);
  - otherwise the stored draft, through `StoreWriter.replaceDraftToken` (read and written in one writer step).
  If neither holds it yet (the draft is still being saved), the result stays known and is applied when that
  composer shows the text (`attach`). After a relaunch, `attach` turns the records back into retryable uploads.
  A placeholder without a record, or with another target's record, can only be removed.
- **Send.** The Send button is off while `UploadToken.contains`, and `OutboxSender.send` refuses such a body
  (`ComposerUploadError.unresolved`). `OutboxRequest.build` adds the body's storage references to
  `metadata.attachments` (sol `mergeChatStorageAttachments`). The message view skips attachments already linked in
  the body (sol `standaloneChatFileAttachments`).
- **Difference from the web.** A pasted non-image file is inserted as a storage link. The web shows it as an
  attachment chip, but the sent message is equivalent. Escaped link labels are parsed (the web's pattern stops at
  `\]`).


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

### 4.5 Account retention and the shared context (build 6)

Every build keeps the account in the same places: Application Support `AmbulandoNative/Store/ambulando.sqlite`,
`AmbulandoNative/Identity/vault.json` and the Keychain services `…identity-vault.v1`, `…session.v1` and
`…background-read.v1` (`ProductionStorage`, pinned by `AccountRetentionTests`). Sample-data mode uses
`Caches/AmbulandoFixture` and its own Keychain services, and is refused on a physical iPhone without
`-AmbulandoFixtureOnDevice`.

The vault keeps complete file protection. A process started while the iPhone is locked (background refresh, transfer
events, an install that launches the app) cannot read it. Up to build 5 that read failure produced `.none` ("no
identity") for the rest of the process. Since build 6:

- A vault that exists but cannot be read is `.unavailable` with `vaultProblem` `.unreadable` (sealed) or `.damaged`.
  It is never `.none`, and the app shows a recovery screen, not import.
- It is read again when the scene becomes active and on `protectedDataDidBecomeAvailable`, and the trusted-device
  session then resumes. An identity already open in memory is never replaced by these refreshes.
- Import is refused while any vault file exists, and (with a Tower connection) for any key except the connection's.
- `vault.pub` holds only the public key, readable after first unlock. It lets the opt-in background read credential be
  matched while the vault is sealed. The state stays locked/unavailable and writes are refused. Vaults from builds 1–5
  get the hint the first time they are read.

Shared context: `WorkContext` (Home, a scope or a scope's channel) is app state keyed by connection and workspace
(`context:<connection>:<workspace>`). The sidebar sets it; Chat's root follows it; `StoreReader.tasks/docs/files(…,
context:)` bound reads in SQL. It is narrowed when its scope or channel disappears from the synced list (lost access
or deletion). A build-5 chat path that opened a channel becomes that channel's context on upgrade.

### 4.6 Workspace surfaces and pins (build 7)

Contracts were read from Tower `/Users/mini/code/wm/tower` at `99d18d4` (the checkout with `routes/context-tree.ts`, the
`personal_pin` record family and canvas elements) and sol at `c7fafcb`. No route or schema was added.

- **Schema v4** adds `context_components`, `context_references`, `canvases`, `canvas_snapshots`, `board_scenes`,
  `board_links`, `workspace_agents`, `agent_activities`, `personal_wapps` and `pins`. All are workspace-scoped and cleared
  with the workspace. The actor-private tables (`pins`, `personal_wapps`) also carry `connection_id` (cascade on
  disconnect) and every read filters by it.
- **Jobs** (`SurfaceSync.swift`): `context:<w>:<s>`, `context-refs:<w>:<c>`, `canvases:<w>`, `canvas:<w>:<c>`,
  `board:<w>:<file>`, `agents:<w>`, `agent-activity:<w>:<c>`, `toolbox:<w>`, `pins:<w>`, `thread-record:<w>:<t>`. Each is
  keyed, coalescing and cancellable like every other read; work beyond a first batch (boards after 6, channels after 12)
  is scheduled at background priority instead of being dropped, and boards on screen are also requested on demand.
- **Events**: `context_component`/`context_reference` refresh a stored tree or component; `canvas*` events refresh the
  list and re-read only snapshots stored on this phone; `personal_pin`, `agent_activity`, `workspace_agent` and
  `personal_wapp` refresh their lists. Reseed lists pins, canvases, the Toolbox and agents in the background.
- **Access loss**: a 403/404 on a tree, component, canvas or channel activity removes the stored copy; a scope or channel
  that leaves the complete lists takes its tree and activity with it; a board scene is kept only while a stored snapshot
  shows the board (`board_links`), and a fetch finishing afterwards stores nothing. Denied naplets are stored as Tower
  projects them: layout only.
- **Parsing** of snapshots (`CanvasScene`, ≤ 32 MB / 2,000 items / 20,000 elements) and boards (`ExcalidrawScene`, ≤ 24 MB /
  20,000 elements / 200 images of ≤ 6 MB) runs in store reads and LiveQuery loads, checks cancellation, and reports an
  over-limit scene as a visible error. Images are decoded with ImageIO thumbnails (≤ 1024 px) off the main actor.
- **Reads never write**: no screen issues a canvas, naplet, element or context mutation; viewport changes stay in memory.
- **Web content** (`LabelledWebView`): HTTPS-only launch URLs without credentials or `.fips` hosts, a non-persistent
  `WKWebsiteDataStore`, no `WKScriptMessageHandler`, and `WebContentPolicy.decide` applied to every navigation including
  redirects and new-window requests (same origin loads in place; another HTTPS origin is only offered to Safari). HTML
  naplets load from a string with sol's sandbox CSP and may not navigate.
- **Pipeline viewer** is not offered: its only contract is the Autopilot control plane over a verified Autopilot
  connection (`/api/owners/:owner/control-plane/v1/pipeline-viewer/{definitions,runs,…}`, capability `pipeline_viewer`),
  which this HTTPS-only Tower client does not have and the web build gates off. A native version needs either a
  Tower-mediated read route or an authorised HTTPS Autopilot connection; both are backend/manager decisions.

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


### 4.7 Section shell, Deck and management (build 9)

Sources: sol `index.html` (`.mobile-section-switcher`, `.deck-columns-track`, sidebar scope/channel controls),
`autopilot-overview-manager.js`, `task-board-state.js` (`selectWorkContextBoard`), `shell-state.js` (view lock),
`channels-manager.js`, `scopes-manager.js`; Tower `routes/flightdeck-pg.ts` at `99d18d4`. No route or schema was added.

- **Shell** (`WorkspaceShell`): one `SectionHost` (a plain container view controller holding a `UIHostingController`)
  per section opened so far, inside a `ZStack`, with the `SectionBar` as a separate layout row below it. An inactive
  host's hosting view is `isHidden` in UIKit (hiding the representable's own view does not hold: SwiftUI manages it), so its
  SwiftUI state (navigation stack, scroll offsets, Deck card, canvas viewport, composer) survives while it is out of the
  accessibility tree and hit testing. Per-section paths live on `AppModel` (`deckPath`, `tasksPath`, …; Chat keeps
  `chatPath`). The shell ignores the keyboard (it covers the bar); each host moves its own content above it. A host's root view is set once: reassigning it on every shell update re-rendered every open section and raised the typing stall to 118–126 ms. The build 8 launch order is unchanged: one context restore
  before the workspace list is observed, generation and edit counters guarding every restore.
- **Destinations**: sidebar choices go through `chooseInSidebar` (Deck, or the locked Chat/Tasks/Docs/Files view;
  Deck returns to its root and Inbox card). In-section controls (the context bar's Home, the Chat channel list, Deck's
  Recent and channel pins) call `selectContext` directly and say where they go. Mentions open the record in its section;
  inside Deck, Agents, Context and Toolbox they push on the current stack.
- **Deck Inbox** (`DeckActivity`): pure projection over stored threads (`deckThreads`: one grouped scan, newest 300,
  then title/root/latest body for those rows only), tasks, docs, files, view states, comment activity and agent activity.
  The card's `LiveQuery` pauses (keeping rows; `start(keepingValue:)` resumes) when Deck is not the current section or the
  card is not shown, so message bursts do not re-run the feed for an unseen card. Found necessary under the 20,000-row
  sync storm, where an always-live feed starved the Canvas snapshot read.
- **Management** (`ScopeChannelManager`): confirmed online requests over the routes listed in the parity matrix, each
  signed with a fresh NIP-98 event, refused while locked, classified into forbidden / duplicate / conflict / not found /
  invalid / offline / saved-but-not-refreshed. Results are written to the store from Tower's answer or a fresh list read.
  The personal scope order reads the current `row_version` before `PUT`; a `scope_order_conflict` stores the other
  session's order and is reported, never replayed.
- **Hidden cards and removed records (build 10)**: the writer emits a `.access` change key whenever it removes stored
  records because they were deleted or are no longer visible (a scope or channel purge, a removed workspace, tombstones,
  a removed Context Tree). `ChangeCoalescer.revisions` counts recorded changes per table synchronously, and `LiveQuery`
  notes the `.access` revision taken just before each read. `start(keepingValue:)` keeps the rows on screen only if that
  revision is unchanged; otherwise the card starts empty and shows only the fresh read. Ordinary changes (new messages,
  edits) still resume without a flash. The remaining window is the instant between a writer's commit and its `record`
  call on the coalescer (the same actor hop), not a delivery batch.

### 4.8 Public profiles, avatars and chat separators (build 10)

Sources: sol `people-profiles-manager.js` (`resolveProfileName`, `resolveProfilePicture`, `getSenderName`,
`getSenderAvatar`), `profiles.js`, `nostr-relays.js` (`PUBLIC_NOSTR_RELAYS`), `utils/naming.js` (`getInitials`),
`index.html` channel thread cards and thread panel; Tower `serializeFlightDeckPgActor` (`actor_id`, `npub`, `kind`,
`display_name` only), `workspace_agents.avatar_url`, the `actor` / `workspace_member_profile` outbox events (already a
directory refresh). No Tower route or schema was added.

- **Sources.** Names come from Tower first: the member's `display_name`, then the workspace agent's name, then the
  `created_by_actor_label` on a message. Tower has no picture for people, so the public kind-0 profile supplies avatars
  and names Tower does not have, as the web client does. Membership stays Tower's: profiles are looked up only for the
  signer, members, agents and recent message senders of the selected workspace (`profileCandidates`, ≤ 500), and a
  profile never adds a person to the directory or the mention picker.
- **Relays (a new network peer).** `RelayProfileSource` opens an ephemeral WebSocket (no cookies, no cache, redirects
  refused) to each of sol's three public relays and sends one `REQ {kinds:[0], authors:[≤ 50]}` per batch, closing at
  `EOSE`/`CLOSED` or after 4 s (handshake included); frames over 512 KB are refused. Nothing is signed or published, and
  no Tower data or credentials are sent; the relays do learn which public keys this iPhone asks about, and its network
  address, as with the web client. `ProfileEventFilter` accepts an event only if it is kind 0, authored by a requested
  key, dated 2020-01-01 to now + 15 min, ≤ 64 KB, and passes the NIP-01 id and BIP-340 check (`SignatureVerifier`,
  swift-secp256k1); the newest `created_at` wins, the lower id on a tie. If no relay answers, the round is an error (the
  engine backs off) and nothing is recorded as missing.
- **Cache.** Schema 5 adds `profiles(connection_id, pubkey)` with the bounded fields shown (`display_name`, `name`,
  picture URL, `nip05`), the event id and time, `found`/`missing` and `checked_at`. Rows belong to the connection (removed
  with it by foreign key) and are pruned when nobody in that connection's workspaces refers to them (also when a
  workspace disappears), then to the 2,000 most recently checked. Found profiles are asked again after 24 h, missing
  ones after 6 h; a forced refresh (Settings › Refresh Nostr profiles) asks everyone and keeps rows until newer ones
  arrive. `ProfileSync` runs as one deduplicated background-priority job per connection and workspace on the `SyncEngine`
  (so a refresh for another workspace is never folded into a running one), scheduled in the foreground when the
  workspace's members or agents change; it never runs in a background refresh window. Turning profiles off cancels
  every profile job of the connection; a round that returns afterwards stores nothing, because the writer re-reads the
  switch inside the same transaction that would store it.
  Screens read `PeopleDirectory` (members, agents and profiles resolved together off the main actor with each snapshot),
  so a cached name is in the first frame, offline and locked included, and a missing one shows the short npub.
- **Avatars.** `AvatarStore` fetches an HTTPS picture only if `AvatarURLPolicy` accepts it (no credentials, no IP literal
  or local host name, ≤ 2,048 characters), through an ephemeral session with no Authorization header, cookies, credential
  store or HTTP cache; at most 3 redirects, each re-checked by `AvatarURLPolicy` (build 12: Blossom servers redirect
  every picture to their CDN); ≤ 5 MiB (build 12, was 2 MB: public photos are often larger; stream cut at the limit),
  `image/*`, known still-image types, ≤ 40 MP. The first frame is decoded as an ImageIO thumbnail (≤ 192 px, never the
  full bitmap) and re-encoded as PNG, which drops metadata. Files are named by the URL's SHA-256 under a versioned directory (`AmbulandoAvatars/v1`, other versions
  deleted), bounded to 400 files / 16 MB; a changed picture is a new URL and file. At most 3 downloads run at once and a
  URL is fetched once however many rows ask; failures back off (6 h for a bad image, 5 min for network trouble).
  `AvatarCenter` keeps decoded thumbnails in an `NSCache`, so a row draws a known avatar synchronously; anything else
  shows initials and loads off the main actor. Turning public profiles off stops the relay job, cancels downloads in
  flight and refuses new ones (a download whose bytes arrive later is not decoded or saved); saved names and pictures
  stay until disconnect, which removes both.
- **Separators.** A channel's messages are drawn as the web's conversation cards (bordered panel per conversation, gap
  between) with the reply bar (rule + "N replies · last …") inside the card. A thread shows its first message, one
  labelled rule ("N replies") and the replies without lines between them. Date labels are added above the first
  message of each day (computed with the snapshot, off the main actor; the label text is resolved at render so
  "Today" moves at midnight), and a "Today" label above unsent messages that follow older history. Rows keep their ids,
  so scroll anchoring, live insertion, drafts and text selection are unchanged.

### 4.9 Names like the web, and the in-app browser (build 12)

- **Names.** `PeopleDirectory` follows sol `getSenderName`: the public profile (`display_name`, then `name`) first, then
  a usable Tower member or agent name, the message's `created_by_actor_label`, then the short npub. `PersonNamePolicy`
  treats Tower's setup placeholders ("Workspace Creator", ...) and npub/hex-only strings as no name.
  `StoreReader.directoryMembers(workspaceId:)` gives every picker and name map (mention picker, task assignees, DM
  picker, task/doc names, sidebar labels, agents) the same resolved label, and those screens also observe `.profiles`.
  Relays get 8 s each (handshake included). Schema and stored data are unchanged.
- **Browser** (`BrowserModel`, `BrowserView`; policy and NIP-07 in `AmbulandoCore/Browser`). Native-only: no Tower or
  shared contract changes, and no new network owner for workspace data (pages talk to their own sites).
  - Full-screen cover over the shell, so the shell's sections, Chat path, scroll and composer drafts are untouched;
    **Ambulando** in the single bottom bar (build 15: all chrome in one bottom row, rarely used actions in the •••
    menu, no top toolbar) and the tab switcher return. Tabs are live `WKWebView`s held in memory
    for the app's lifetime (not restored after relaunch), at most 12.
  - Entry: the globe button in every section's toolbar (with the tab count), HTTPS links anywhere in the app
    (`openURL` on the shell; other schemes keep the system behaviour), links leaving an HTML artefact, and the WApp
    and artifact launchers (Deck › Hello and Links › Apps, Toolbox, Context Tree artifact links) through
    `BrowserModel.launch`, which checks the address with `WebContentPolicy.launchURL` and `BrowserURLPolicy` and shows
    the tab that launcher opened before rather than adding one. HTML naplets keep the sandboxed labelled view (CSP, no
    script bridge, no network) and never get `window.nostr`.
  - `BrowserURLPolicy`: pages are HTTPS only, without URL credentials or `.fips`; `about:blank` for new windows;
    frames may also use `about:`, `data:`, `blob:`. `mailto`, `tel`, `sms`, `facetime(-audio)`, `lightning`, `nostr`
    are handed to iOS after a confirmation, and only from a user-started navigation. Popups (`target=_blank`,
    `window.open`) become tabs built from WebKit's configuration; `window.close()` closes the tab; `alert`/`confirm`
    are native alerts naming the host.
  - Website data lives in its own persistent `WKWebsiteDataStore(forIdentifier:)`, separate from the HTML-artefact
    view's non-persistent store; the browser menu clears it.
  - `window.nostr`: a document-start script in the page world, top frame of HTTPS pages only, calls a
    `WKScriptMessageHandlerWithReply`. The handler answers only the main frame whose `securityOrigin` equals the tab's
    committed origin; requests carry the tab's document number (bumped on every main-frame commit). `NIP07Broker`
    asks per origin before revealing the public key (remembered in `app_state` `browser.sites.v1`, forgettable from
    the menu), shows a sheet with origin, kind, time, content and tags for **every** `signEvent`, and only for kinds
    22242/27235 offers "until Ambulando locks" per origin and kind. Events are bounded (kind 0–65535, content
    ≤ 256 KB, ≤ 2,000 tags) and a foreign `pubkey` is refused. Navigation, reload, tab close and lock cancel waiting
    requests; after the user answers, lock and document are checked again before and after signing. Locking clears
    the until-lock grants and refuses everything; removing the identity or disconnecting closes tabs and forgets
    sites. `getRelays` returns `{}`; NIP-04/44 reject. JavaScript only ever receives the public key and signed events.

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

Older edits and deletions now arrive as events (§5.2 below); a forced refresh still re-reads the whole channel.

### 5.2 Live updates and event cursor (WP5, delivered)

Contract read from Tower `GET /workspaces/:w/events` and `GET /workspaces/:w/events/stream` (`flightdeck-pg.ts`):
events are the actor-visible rows of `flightdeck_pg_outbox_events` after an opaque cursor (`row_version` order, at
most 200 per page). The stream polls the same query every second, sends `connected`, `flightdeck_pg.event` (with
`id`) and `flightdeck_pg.error` frames and a heartbeat comment every 25 s, and closes with
`workspace_access_revoked` when membership or `workspace.read` is lost. Events are never pruned; a missing cursor
means row version 0 (the whole history), so the client never opens without one.

- **One cursor per connection and workspace**, in `app_state` (`events.cursor:<connection>:<workspace>`), advanced only
  by the `events:<w>` job and saved only after the batch it covers is stored.
- **Seeding.** Without a cursor the job reads the head from `GET /sync?limit=1` (`through_cursor`), saves it, then
  catches the lists up directly (scopes/channels, inbox, channels this phone has read, tasks, docs, files). History is
  never replayed.
- **Applying a batch** (`EventPlan`): deletions are applied as tombstones (message, thread with its messages, task and
  doc with comments and cached body, file, comment, reaction). Other events become targeted reads: one message, thread,
  task (+ comments), doc (+ comments; a cached body is refreshed when the version moved), the channel's files,
  reactions, view states. A record already stored at the event's `entity_row_version` is not fetched. Membership/grant
  events rerun discovery, scope order and directory. More than 100 events in a batch fold into per-channel list
  catch-ups. Visible-channel work runs first, three reads at a time. A 403/404 on a record removes the local copy.
- **Bounded catch-up.** A poll reads at most 10 pages (background: 5). A longer backlog, or a cursor Tower rejects
  (400), is a gap: the job reseeds at the head and schedules the list catch-ups. 403/404 on the event route reruns
  discovery, which removes a workspace that is no longer listed.
- **Access loss.** A complete scope or channel list that no longer contains a channel deletes the channel's stored
  messages, threads, tasks, docs and bodies, files, folders, comments, reactions and view states. Drafts and unsent
  rows stay. Cached downloaded file bytes of that channel remain in Caches until disconnect or system purge (gap).
- **Foreground stream** (`LiveStream`). Only while the scene is active and reads can be signed: a bounded catch-up,
  then the stream at the stored cursor with a fresh NIP-98 header (the header form; no query token). Frames are parsed
  incrementally (`SSEParser`), queued on the workspace's `LiveFeed` and applied in ≤ 250 ms batches by the same job.
  A batch is applied only if it starts exactly at the stored cursor. The receive buffer is bounded (2 MB): a slow
  reader fails the stream instead of dropping bytes. No data for 60 s, a closed stream, an overflow or an error frame
  reconnect with backoff (2 s → 60 s) from the stored cursor. Access revocation stops the stream and reruns discovery.
  Leaving the foreground, locking or switching workspace closes it.

### 5.3 Background execution (WP5, delivered; scheduling is up to iOS)

- `BGAppRefreshTask` `studio.otherstuff.ambulando.native.refresh` is registered in `didFinishLaunching` and requested
  no earlier than 15 minutes after entering the background and after each run. The handler requests the next window
  first, runs `WorkspaceSync.backgroundRefresh` (the same keyed jobs at background priority: event catch-up for up to
  5 workspaces, selected first; unsent messages and changes only if the identity is unlocked in memory), and calls
  `setTaskCompleted` once. The expiration handler cancels it, which cancels every job; stored pages and cursors stay.
  The outcome (completed, expired, skipped because locked, failed) is saved and shown in Settings.
- Leaving the foreground with unsent items asks iOS for its finishing time (`beginBackgroundTask`) and waits for the
  engine to go idle, cancelling at expiry.
- Info.plist declares only `UIBackgroundModes = fetch` and the task identifier. No audio, location, VoIP or other
  keep-alive modes. iOS decides whether a refresh window is granted; the simulator does not grant them on demand, so the
  simulator and device evidence runs the same pipeline from a labelled sample-data hook.
- **Background transfers.** Uploads to a presigned object-store URL (another HTTPS host) and downloads from Tower's
  presigned `download_url` run in a background `URLSession` (`studio.otherstuff.ambulando.native.transfers`). Requests
  are unsigned (an Authorization header is a precondition failure), cookies are off and redirects are refused. Tower's
  own storage routes stay signed and in-process. Each transfer has a stable persisted key (upload: storage object id,
  download: file id + sha256). A finished transfer is picked up by the next attempt instead of repeated, including
  after relaunch (the session is recreated at launch, and `handleEventsForBackgroundURLSession` hands over the
  completion handler). A lost task is restarted. Waiting can be cancelled without cancelling the system transfer.
  Prepare and complete stay with `TowerAPI.store`, which commits only after Tower verifies size and hash. Downloads are
  hashed (streamed) against the file's sha256 before entering the cache.

### 5.4 Responsiveness budgets

Measured budgets (WP2 core tests; WP5 UI on the simulator plus first phone readings; WP6 phone profiling):

| Budget | Target | Evidence |
| --- | --- | --- |
| Main-actor job latency during sync storm (20k rows) | p99 ≤ 16 ms, max ≤ 50 ms | `SyncStormTests` heartbeat probe |
| Screen read latency during storm (reader vs. writer) | p95 ≤ 25 ms | `SyncStormTests` |
| Coalesced UI change notifications | ≤ 10 per second per observer | `ChangeCoalescerTests` |
| Typing in the chat composer during a 20k-row storm (simulator, sample data) | no dropped characters; main-actor p99 ≤ 16 ms, max ≤ 50 ms | `ChatFlowUITests.testTypingDuringSyncStorm` with a matched no-write control and a plain-keyboard diagnostic. WP5 build 4 full-suite run: storm p99 7.78 ms, **max 65.5 ms: the 50 ms max target is not met**; control max 64.9 ms; after the first keystroke storm max 43.1 ms vs control 60.3 ms. No dropped characters. See §5.5 for attribution |
| Keystroke-to-render (composer) | p95 ≤ 16.7 ms at 60 Hz, no dropped characters | Not measured as such. The probe and frame monitor cover the typing window; per-keystroke render timing on the phone is WP6 |
| Hitch ratio while scrolling chat under storm | < 5 ms/s (Apple "good") | Not met / not measurable on the simulator: `XCTOSSignpostMetric.scrollDecelerationMetric` reported no data, and the in-app frame monitor (60 Hz simulator display link, including keyboard dismissal) reads 48–75 ms/s in storm and control alike. Phone measurement is WP6 |
| Cold launch to cached workspace list | ≤ 400 ms after first frame | In-app signpost `launch-to-cached-list`: simulator 297–316 ms (asserted ≤ 400 in `PerformanceUITests`); iPhone 15 Pro (Debug build 4, sample data) 130 and 134 ms. `XCTApplicationLaunchMetric` first frame responsive, simulator Debug: 1.03–1.12 s |
| Channel open (navigation) | no budget set; measured | `navigationTransitionMetric` 0.50–0.51 s (simulator, includes the push animation). Profiled main-thread list layout at first open 111 → 74 ms after the WP5 row changes (single traces) |

Build 6 (sidebar context, thread panes and rich rendering) full-suite run on the simulator, same tests: storm p99
13.32 ms, max 66.11 ms (after first key p99 12.60 / max 46.33 ms); no-write control p99 23.70 ms, max 59.06 ms;
plain-keyboard control p99 24.46 ms, max 47.41 ms. No dropped characters. The 50 ms max target remains unmet in the
storm run, as in build 4/5, and is not relaxed. An isolated run taken while another simulator was building on the same
Mac read storm p99 16.71 ms; it is not used as evidence.

Build 7 (new surfaces; the composer and sync paths are unchanged apart from the new event families) full-suite run on a
fresh iPhone 17 Pro simulator, same tests: storm p99 13.79 ms, max 57.17 ms (after first key p99 9.32 / max 46.37 ms);
no-write control p99 25.65 ms, max 58.52 ms; plain-keyboard control p99 24.69 ms, max 57.82 ms; no dropped characters;
first frame → cached list 234–257 ms. The 50 ms max target remains unmet in storm and control alike and is not relaxed.
No phone measurement of build 7 exists.

Build 9 (section shell; the composer itself unchanged apart from the Hide keyboard slot) on the "Ambulando Native
Validation" simulator, three iterations each of the same tests: storm p99 12.21–15.89 ms, max 57.12–58.23 ms (after first
key max 45.05–48.45 ms); no-write control max 50.56–57.90 ms; plain-keyboard control max 56.90–58.15 ms; no dropped
characters in 9 runs. Two intermediate versions regressed and were fixed before this: rebuilding every section host's
root view on each shell update plus hiding the bar on keyboard show (first-key stall 118–126 ms), and a keyboard
accessory Done button in Chat (83–102 ms). The 50 ms max target remains unmet, as in builds 7–8, and is not relaxed.

### 5.5 WP5 responsiveness work and attribution (simulator)

Time Profiler traces of the control typing run (`tmp/` evidence, not committed) attribute every main-thread stall of
50 ms or more in the typing window to:

- **XCTest accessibility snapshots** (`XCTElementSnapshotRequest`), which the UI-test runner takes between typed
  chunks; they explain the stall about 1.1 s into typing in every variant.
- **UIKit keyboard presentation** at the first keystroke (`UITextView becomeFirstResponder` →
  `UIKeyboardSceneDelegate setInputViews`).

Keystroke handling itself peaked at 23–39 ms. None of these stalls came from sync or app code. Turning off
autocorrection (diagnostic only) did not change the result. So the remaining gap against the 50 ms target is
measurement-harness and system work on the simulator; the phone run in WP6 decides it. The target stays as written.

App-attributable costs found and fixed in WP5:

- `LiveQuery` compared large snapshots on the main actor and re-assigned `loaded`/`error` on every reload. Each
  assignment invalidated every reading view. Comparison now runs on the concurrent executor (`@concurrent`), and only
  changed state is assigned.
- Sync status reached screens on every job start and finish. It now updates at most 4 times a second, only on change,
  and chat screens read it in small subviews.
- Message rows parsed attachment JSON, built mention-styled text and parsed and formatted dates in every body
  evaluation. These values are now prepared off-main into a bounded display cache. Time labels are memoised per day,
  and plain messages render as verbatim `Text`.

Zero shared-resource impact cannot be guaranteed. CPU, memory bandwidth and
SQLite WAL checkpoints are shared, so these targets are measured, not assumed.

## 6. Platform limits (honest scope)

- **Background execution**: iOS suspends apps. WP5 uses `BGAppRefreshTask` (opportunistic, short, cancelled at
  expiry) and a background `URLSession` for presigned transfers (§5.3). There is no background SSE and no fake
  audio/location modes. SSE runs only in the foreground and resumes from the stored cursor.
- **Unlock and stay unlocked (build 5)**: whenever an existing identity is locked, the app shows a full-screen unlock.
  - **What is stored:** a PIN unlock (or import) keeps the key in a device-only Keychain item
    (`studio.otherstuff.ambulando.native.session.v1`, `WhenUnlockedThisDeviceOnly`, never synchronised). On later
    launches it is resumed without the PIN only if it matches the vault.
  - **Revocation:** Lock now, removing the identity and disconnecting revoke it fail-closed (revocation marker before
    the Keychain delete). After a manual lock the PIN is always required.
  - **Background launches:** the item is unreadable while the iPhone itself is locked, so a background launch on a
    locked device stays locked.
  - **Separate from the read credential:** this session is independent of the background read credential below, which
    never unlocks the UI.
- **Signing in the background**: without the session above the identity key exists only in memory while unlocked
  (§1.3).
  - **Suspended and still unlocked, or relaunched in the background while the device is unlocked (session resumed):**
    a granted refresh window does everything, including sending.
  - **After iOS ends the process:** the app relaunches locked and makes no request (`skippedLocked`), unless the user
    turned on *Refresh while locked*.
  - **What that option stores:** a copy of the full signing key in a separate Keychain item
    (`studio.otherstuff.ambulando.native.background-read.v1`, `AfterFirstUnlockThisDeviceOnly`, never synchronised),
    together with the pinned origin and workspace ids. It is not a server-issued or cryptographically read-only
    credential. An app-enforced policy (`ReadPolicy`) lets it sign only NIP-98 `GET` requests under
    `/api/v4/flightdeck-pg/workspaces` on that origin for those workspaces. It never signs kind 33358 or a request with
    a body, and the UI keeps showing *locked*. Sending still needs the PIN.
  - **Revocation:** Lock now, turning the option off and removing the identity write a revocation marker before
    deleting the Keychain item. While the marker exists the credential is never loaded or used, so revocation fails
    closed even if the delete fails (which Settings reports).
  - **Default and contracts:** the option is off by default. No Tower contract changed.
- **Parallelism**: Swift concurrency within one process. There is no claim of
  arbitrary parallel OS processes.
- **Push**: Tower implements Web Push (VAPID) only, in
  `flightdeck-pg-notifications.ts`. APNs needs a separate, evidenced server
  capability and is not in scope.
- **Transport**: HTTPS only. The live `sb4` descriptor advertises Tower
  `https`/`nip-98` and no FIPS service. FIPS is a WMapp-shell capability, so
  native-ip does not offer it. If a FIPS-only endpoint is selected, the app
  refuses it rather than falling back to HTTPS.
- **Web content**: only records that are themselves HTML documents are web
  content, and they are not counted as native parity. HTML artefacts open in an
  explicitly labelled, sandboxed web view; WApps' own UIs and Context Tree
  artifact pages (HTTPS) open as in-app browser tabs (§4.9). Canvas, naplets, Excalidraw, the context
  tree and agents are native since build 7 (§4.6); the pipeline viewer needs an
  Autopilot contract this app does not have.
