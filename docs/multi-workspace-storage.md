# Native workspace storage boundaries

Native multi-workspace storage uses one actor-owned SQLite file per full resource boundary:
normalised Tower origin, signing identity, application namespace and workspace ID. The file
name is a versioned, length-delimited SHA-256 digest; labels and server-generated IDs are
never assumed to be globally unique. Each file retains the existing writer/read actors,
indexes, transactions and change coalescer. Notifications and local queries cannot cross
the boundary because they never share a store instance.

This deliberately departs from the initial shared-file preference. The previous schema has
many workspace-only content keys, joins, deletes, search triggers and change notifications.
Physical partitions establish a consistent boundary for all those operations rather than
relying on a partial rewrite. Network jobs still need the same full boundary in the shared
scheduler; file isolation alone does not isolate deduplication, cancellation or live feeds.
Attachment caches, transfer identities, drafts and navigation must use the same boundary.

## Migration policy

Before creating partitions, the store pool creates one consistent SQLite backup of the
legacy catalog using SQLite's backup API, including committed WAL pages. The backup is
written to a temporary file and atomically moved into place. Existing backups are never
overwritten. The source remains available for recovery and is never deleted by migration.
The original store continues as the connection/discovery catalog; it must no longer serve
content or send its legacy outbox after the application adopts workspace runtimes.

Each destination imports in a single transaction and records a completion marker in that
same transaction. An interrupted import rolls back, and a completed import is never
repeated, including after local rows have been edited, acknowledged or removed. The app
must not fall back to the legacy content store if a partition cannot be opened.

- Workspace-only cached rows are copied only when the backup lists exactly one connection
  for that workspace and its origin, signer and application match the requested boundary.
- Connection-qualified private rows are copied only for the exact connection and workspace.
  Rows with application/origin/signer fields must match those fields too. Drafts without an
  application field require a matching connection/workspace/application discovery row.
- Only recognised, exactly qualified navigation and cursor state is imported. Workspace-only
  scope order is imported only with uniquely owned cache. Unknown app state remains in the
  preserved source; it is not broadcast into every partition.
- Ambiguous cache is retained in the backup and omitted from active partitions. It is
  refetched through the correct connection after access validation. No ownership is guessed.
- Outbox request blobs and IDs, write ambiguity flags, staged attachment references and
  draft bytes are copied unchanged. Interrupted sends are recovered by the existing
  idempotency/reconciliation paths after import, before resuming writes. The catalog's old
  queues must never run alongside the partition queues.
- Downloaded file bytes are copied into the new boundary cache only when metadata was
  uniquely imported and a valid SHA-256 matches both the source and copied destination.
  Metadata is read in bounded pages and hashes stream in bounded chunks. Unhashed,
  corrupted or ambiguously attributed old bytes remain in the original cache; they are
  not exposed through another connection. A completion marker makes restoration idempotent.
- Unsaved board drafts move from the legacy connection/workspace directory to the full
  boundary directory only with uniquely imported snapshot provenance. Migration requires
  a UUID file name, valid base-version UUID and positive number, and a valid bounded board
  scene. It copies without overwriting current drafts, retains original files, and records
  completion so a discarded migrated edit cannot reappear. When ownership cannot be proved,
  original draft files remain available for recovery and are withheld from active workspaces.

Callers must use the canonical connection returned by the catalog's `saveConnection`.
The pool refuses an alternate local connection ID for the same normalised origin/signer
instead of stranding private state behind an alias.

Explicit Disconnect retires that connection's partitions after its sync work and observers
are stopped. Actor-owned SQLite handles close and reject stale reads/writes, the pool evicts
them, and matching origin/signer directories move under `WorkspaceStores/Retired/` for local
recovery. Other connections and the frozen legacy backup remain in place. A reconnect gets a
fresh partition and cannot resurrect the disconnected account's old queue. Workspace pause
never retires a store or moves its files.

Migration neither validates current server access nor bypasses identity lock. Runtime resume
must revalidate access and catch up before sending pending work. Removing access and pausing
a workspace have different meanings: pause preserves its file; authoritative access loss
removes inaccessible cached content through that runtime's store.
