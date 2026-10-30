# Native multi-workspace navigation and sync

The iPhone and Mac clients can enable several workspaces in one navigation column.
Selection is opt-in: an existing installation starts with its remembered workspace.
The workspace chooser groups choices by Tower and can add another Tower using the
same unlocked identity. Each enabled workspace has its own Home, scopes, channels,
collapse preference, order and colour. Shared Unread & Active rows retain the source
workspace and route through the exact account boundary. Colour supplements the name;
the context bar and chat composer identify the workspace explicitly.

## Runtime ownership

`WorkspaceBoundary` identifies normalized Tower HTTPS origin, signer, application and
workspace. `WorkspaceStorePool` owns one SQLite partition per full boundary; see
[migration policy](multi-workspace-storage.md). The original database becomes the
connection/discovery catalog. It is never the runtime outbox or content fallback.

`EnabledWorkspaceEntry` owns a `NativeWorkspaceRuntime`: partition, cursor/feed,
foreground stream, scoped scheduler, access state, outbox, write sender, document
saver, command manager and boundary-rooted file cache. Selecting a different entry
changes the one content pane without stopping the other enabled entries. Queries and
change notifications stay inside their partition. Delayed UI work checks context
revision and connection/application before applying a result.

All scoped scheduler facades feed a single bounded `SyncEngine`. Keys contain the
connection and full workspace boundary. Equal-priority jobs rotate between boundaries;
per-connection occupancy leaves room for another Tower in both background and
foreground work. A foreground slot is reserved for visible work and sends. History
hydration remains bounded and cached navigation does not wait for network catch-up.

## Pause and resume

Unticking synchronously closes read and write activity gates, then cancels that
boundary's queued work, retries, reads, stream and document leases. A generation lease
follows scheduled work across child tasks and actor calls. Transport and SQLite
materialisation reject old-generation results after an immediate pause/re-enable.
Local draft and preference writes remain possible without a network lease. Durable
send-state reconciliation can retain an unknown outcome while content materialisation
is fenced. Other workspaces, including those on the same Tower, continue.

Resume shows cached navigation and revalidates workspace/application access, catches
up the saved event cursor, and opens the write gate only afterwards. Frozen request
bytes and request identifiers survive cancellation; replay/reconciliation uses the
existing Tower idempotency contracts. No paused workspace can submit through another
connection. Access loss closes its write gate and removes only that partition's
inaccessible server content; local pending work stays available for recovery.

Empty selection is persisted explicitly. It shows the workspace chooser instead of
silently enabling a default on launch. Collapse and reorder affect presentation only.

## iPhone background policy

Streams run in the foreground only. Opportunistic background refresh rotates its
starting boundary across launches/windows and schedules enabled workspaces through
the shared pool. Expiration cancels the window; already committed pages/cursors stay.
Push hints can fetch only an enabled, unambiguously matching origin/workspace. A tap
never enables a paused workspace implicitly. Credential lock restrictions still apply;
the existing optional read credential is pinned to its configured origin and cannot
sign for another origin. No APNs/backend capability is added by this feature.

Workspace transfers use the cancellable runtime HTTP path and scheduler rather than
the old globally keyed system transfer registry. An interrupted upload retains its
prepared object for explicit retry. This sacrifices system-managed continuation of
new transfers while the app is suspended in order to enforce scoped pause and avoid
cross-Tower transfer collisions. Existing global transfer records remain recoverable.

## Validation surfaces

Core fixtures exercise identical server IDs across Towers and identities, application
namespace changes, idempotent migration, frozen writes, pause/re-enable races at SQL
and transport boundaries, concurrent event streams, fair scheduling and access loss.
`MultiWorkspaceUITests` covers native iPhone opt-in selection, shared unread routing,
collapse and final pause/relaunch/re-enable. The Test-only Mac multi-workspace check
uses isolated sample credentials and stores and writes its report only to ignored
handoffs. These fixtures do not certify real Tower or installed-device behavior.

Live multi-Tower traffic, physical iPhone background expiry, and installed MacBook
verification require their own evidence. A successful source build/push is separate
from installing or testing an app on a user's device. Web, Android, backend routes,
a combined Home dashboard and a second Mac content pane are outside this feature.
