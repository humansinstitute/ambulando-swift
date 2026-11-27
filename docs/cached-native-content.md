# Cached Goals and napplets

On an unlocked device, previously verified Goals and previously opened napplets can restore their read content from the workspace database before online validation finishes. A first open with no usable snapshot still needs a connection. Cached content is a read snapshot, never a server credential or permission to write.

## Storage and isolation

`LocalContentSnapshot` uses the existing workspace-partitioned `app_state` storage and the unlocked identity's existing self-encryption key. It introduces no server endpoint, schema migration, credential, key store or parallel cache catalogue. The sealed payload binds origin, account, workspace, app and snapshot slot. Larger snapshots use bounded NIP44 chunks. The outer envelope’s `digest` field contains a separately NIP44-encrypted SHA256 of the complete payload; decryption and comparison protect chunk order as well as content. Locks prevent decryption; changing accounts or backends changes the cache namespace.

Goals stores its privately verified channel location and File/version references separately from individual goal documents. The complete goal format retains dates, focus rank, checkpoints, timeline, links and unknown fields. Ordinary writes still re-read server state and use the existing versioned File contract. Cached Goals agent grants are not represented as fresh administrative authority.

File-backed napplets store an exact verified code version/digest/binding together with confirmed JSON data and its displayed base version. Local approval remains a separate, exact-code trust receipt. The daily tracker retains the bytes it delivered to the frame for its existing format/history validation. Cached reads establish both the displayed base and delivered bytes; a first save cannot silently use a newer background version.

Installed runtime v3 snapshots include installation, immutable code and collection authority. Read results are keyed by release, installation revision, collection authority, dataset selection and exact list/get arguments. Only previously completed reads can restore; unvisited datasets and pages still need a connection. Runtime writes and management operations remain online and use their existing revision and authorization checks. The older workspace bundle host restores its verified bundle/projection together.

## Refresh and removal

Background validation leaves usable content mounted on connectivity failures or expired authentication. Explicit access denial, removed resources and verified code/binding changes remain distinct from network failures. File/channel/workspace removal paths invalidate dependent snapshots, leaving drafts and unrelated records alone. A missing individual Goal does not discard the other cached Goals. Routine access notifications do not evict the cache.

Clean generic/runtime frames refresh through a separately warmed frame, swapped only once ready; they do not rely on sending a second response for a request ID the app already consumed. Dirty frames retain their original DOM and displayed revision. Conflicts retain drafts and require explicit refresh/reconciliation. Cached content does not make arbitrary napplets support offline writes.

## Validation and parity

Core checks cover encrypted durable restoration, chunk integrity, lock and backend boundaries, corruption, exact channel/file invalidation, unrelated Goal retention, cached-open/edit/save and stale-base conflict. The opt-in Mac cached-content check measures actual SwiftUI Goals and WebKit napplet rendering against a delayed/failing synthetic transport. A second Test-app process also restores Goals and verified code/data offline from the same durable identity and database. These checks do not establish installation or live-user behavior on another Mac.

The shared Swift implementation preserves iPhone source compatibility. iPhone UI execution, device lock/relaunch timing and web parity require separate follow-up validation. Android delivery is independent of the Mac source build and retains its own signed release and upgrade checks.
