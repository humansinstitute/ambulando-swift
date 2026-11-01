# Installed workspace napplets

Toolbox and Deck Apps show the current workspace's installed static napplets alongside personal WApps. Project
Register opens inside a private native host and can read and save its statuses and notes using Tower's existing
organisation-data API. It does not open the register's maintenance server or create a second register.

Personal WApps still open in browser tabs. Canvas HTML File naplets still use their separate bridge-free renderer.
A workspace installation is immutable reviewed HTML, with a digest and declared capabilities; it is never treated as
an arbitrary URL. Publishing and installing remain on the existing web/agent surfaces.

## Authority and lifecycle

Discovery reads the authenticated org-data catalogue. The core validates the workspace identity tuple, installation
manifest and SHA-256 before storing launcher metadata only, under the connection/workspace partition. Metadata from
an earlier app run is not authority. A failed catalogue or snapshot read removes discovery authority. Launch always
reads a fresh complete snapshot; no organisation rows or bundle HTML are saved in the local launcher cache.

The host loads an opaque `sandbox="allow-scripts"` iframe inside a nonpersistent WKWebView. Its parent document owns
the native message handler. Both layers validate the sender, and native checks the current random session and exact
bridge-v1 message keys. The bundle receives `window.nappletSession` and ordinary parent message events, including
records grouped by type key. It never receives a key, bearer credential, Tower client or arbitrary request method.
Host CSP, a resource blocker and a navigation delegate constrain resources and reject external navigation.
Opaque local WebKit documents lack the secure-context-only `crypto.randomUUID` API; the host supplies RFC 4122 v4
UUIDs from `crypto.getRandomValues` before bundle execution, preserving durable mutation IDs without weak randomness.

Ready/refresh/close/dirty and capability-scoped typed record/schema writes are supported. Installed bundles cannot
publish/install other bundles, run SQL, choose a workspace or request signatures. Profile/DM and built-in catalogue
navigation intents are not implemented in this host; ordinary canvas HTML does not gain any bridge capability.
Tower's own read/write grants remain independent of the declared bundle capabilities. Locked background-read
credentials cannot write. Record changes retain their original expected revision and operation ID; there is no
unconditional overwrite or automatic retry of an uncertain write.

Background reauthorization keeps the mounted document and scroll/filter/draft state while blocking writes. It
compares permitted datasets, fields, references, identities, capabilities and installations before delivering a new
projection. Ordinary values/revisions may change without invalidating a draft. An authorized save conflict retains
the existing document and original edit revision only after a successful unchanged-authority read. A denied write,
failed read, narrowed authority, context switch or close destroys the browsing context, including scripts that
ignore state messages. Confirmed explicit refresh destroys/remounts the document and discards unsaved edits.
The host checks authority on visible foreground intervals and discovery invalidations, with bounded network/readiness
timeouts. Pending writes block user close/refresh; context loss takes precedence over draft retention.
Save row edits before changing native sections: Refresh/Close confirmation and interactive Back are guarded, but
other section changes destroy the view and discard unsaved napplet drafts. There is no shell-wide navigation guard
or persisted offline napplet draft in this release.

## Verification

`InstalledNappletTests` exercises signed discovery, metadata-only storage and viewer partitioning, denial, bridge
projection shape, revision conflict/idempotent replay, malformed/session/capability/path rejection and digest/identity
validation. An optional `AMBULANDO_NAPPLET_SNAPSHOT` environment path lets the same parser inspect an authorized local
snapshot without adding private records to source control.

`InstalledNappletUITests` drives a real WKWebView and opaque iframe against the isolated signed sample Tower: launch
from Toolbox, edit/save, close/reopen, retain an unsaved draft on cancellation and discard only after explicit
confirmation. Its sample data and operation IDs never reach a human workspace. Local fixtures and build success do
not establish physical device installation or authenticated live acceptance; those are reported separately.
