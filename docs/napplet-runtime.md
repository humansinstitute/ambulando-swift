# Common napplet runtime (v3)

Mac build 108 and iPhone/iPad build 109 add the common v3 cartridge runtime alongside
existing File-backed apps. This source feature requires the corresponding NStack
napplet API; a local build or synthetic test does not establish server activation
or installation on a physical device.

Workspace apps are discovered from NStack's current workspace/application
installations. A stable napplet slug identifies one installation independently of
display name, bundle version and source File. Bot publication and requester-private
initial audience are server operations; refreshing Apps discovers authorized entries
without bundling app templates into the host. Audience may include users and agents,
and grants discovery/open independently of collection permissions.

The shared strict v3 manifest and frame fixtures are under
`AmbulandoCore/Tests/AmbulandoCoreTests/Fixtures/napplet-runtime-v3/`. The common
manifest declares named personal/team collections, schema versions and operations;
requests support bounded keyset pagination, individual record identity and exact
revision updates/deletion. Frame `base_revision` maps to HTTP `expected_revision`.
Record writes are limited to 256 KiB. The host binds workspace, application, napplet,
identity and selected datasets; frames cannot override these or issue arbitrary
URLs, SQL, management commands or signing requests.

WorkspaceSync owns authenticated network work and materializes discovery/results
in the local store. Apps uses a live query. The existing Tower client owns NIP-98
and transport; no separate service, catalogue or database is introduced. The
sandbox is nonpersistent and network blocked, with main-frame/source/session
binding, replay protection, one operation at a time and a 45-second deadline.
Uncertain writes are not automatically retried. The initial runtime is online-only.

NStack authenticates the publisher and immutable active bundle. Native rechecks
SHA-256 and exact manifest equality. The audience-bound `/bundle` endpoint grants
only the published bytes; source File access is not broadened. Code-only changes
within approved declarations load automatically on the next active check without
digest-based re-consent. Dirty/in-flight work defers automatic replacement. Broader
collection scope/schema/operations or capability resources/operations require
review. Pending server releases require human manager approval; device approval is
separate. Declining leaves the active permitted release. Prior release metadata
remains server-owned; this client does not expose a rollback control or promise
access to historical source bytes through the audience endpoint.

Device approvals bind backend, Tower, workspace service, workspace, app, viewer,
stable napplet and authenticated publisher. They exclude code digest, title and
bundle version from access comparison. Unsupported host versions and personal
capabilities display compatibility explanations. No Nostr DM read/decrypt/send,
plaintext persistence or agent-DM access is implemented. These are separate grants;
no raw keys, credentials or ambient signing/decryption enter a napplet.

Audience and data controls are host-owned. Users can create an explicitly private
collection, replace read/write npub grants where they own the data, and choose an
authorized dataset. Personal collections prefer the acting owner's dataset;
otherwise resolution requires one unambiguous match. Explicit host selection is
memory scoped and revalidated on each command. Context/identity loss destroys the
frame and pending work; fresh collection metadata detects grant changes.

Removal always confirms scope. Keep retains collections for reinstall; delete
requests deletion of collection payload/history subject to NStack ownership checks.
Both preserve source Files and their history. Apps can reconnect a removed app by
stable ID, reading its current removed revision before the guarded reinstall;
kept collections reconnect across devices and deleted data is not recreated. Existing File v1/v2 trackers remain
on their original bridge and data/history. An explicit compatible import can copy a
whole JSON File object into one new named record, with immutable source provenance,
without rewriting the original. The user must confirm target schema compatibility
and team sharing. This is not an automatic conversion of tracker days or a claim
that existing File apps already use collections. Conflicting records fail rather
than overwrite; destructive migrations are unsupported.
