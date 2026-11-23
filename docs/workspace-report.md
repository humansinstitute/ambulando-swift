# Workspace Report

Mac build 106 and iPhone/iPad build 107 add Workspace Report to Deck Apps and Toolbox.
The existing internal link `/flight-deck?workspaceid=<UUID>&napplet=workspace-report`
opens the same native app. Absolute links are intercepted only for the connected
HTTPS origin; this adds no OS domain association.

Opening discovers existing private report code Files in Note to self. A single
instance opens, several offer a chooser, and none offer explicit setup. Setup
stores one HTML File with the `workspace-report` manifest and workspace binding;
it creates no report JSON data File. Incomplete discovery fails closed. A setup
whose result is uncertain must be checked before another creation attempt.

The exact shared inline bundle renders rolling 7/30/90-day or all-time message
activity, distinct conversations, current inventory and task states, and the top
ten channels with explicit remainder and coverage. Inventory is current, not a
claim about completions during the selected period. UTC and server snapshot time
are visible. No demo totals are used outside the opt-in synthetic test host.

The separate read-only parser admits only `read`, binding `report`, a fixed range,
nonce and unique request ID. The native sync owner makes the signed fixed PG
`workspace-report` GET with `top_n=10`. The opaque frame receives validated
aggregates only, without identity, URLs, content bodies, credentials or writes.
The host verifies exact private code bytes/version/metadata and current membership
before and after each aggregate read. Context loss, denial, malformed results or
request timeout remove the frame and its in-memory totals. No aggregate disk
cache is used. An older server without this route shows unavailable.

Consent is stored locally in the app container, excluded from backup, partitioned
by origin, service, connection, viewer, workspace, app and code File. Exact source
digest, manifest/workspace binding and read-only capability are remembered.
Channel membership/count changes do not fingerprint or repeatedly prompt the
viewer; the server applies current access on every read. Forget approval removes
the receipt. Approval never substitutes for server authorization.

Daily Metrics retains its separate binding, parser, private JSON read/save path,
dirty/save guards and Update app behavior. Ordinary HTML stays bridge-free.

Validation uses fixed signed-transport fixtures, strict count/identity/range and
manifest checks, and isolated native WebKit/UI checks. Local unsigned builds and
GitHub source delivery do not establish backend activation, live-account counts,
TestFlight distribution or installation on Pete's devices.

## Generic storage capability

The common v2 cartridge runtime also supports a `workspace-aggregate` binding
with capability `version: 2` and `operations: ["read"]`. The outer manifest and
File metadata remain version 2, with the same workspace resource binding. The
frame's exact `read`/`range` request is unchanged. Capability version 1 and the
legacy report retain their strict activity-only response and request behavior.

Only an approved version 2 binding adds `storage=workspace` to the existing
signed report route. The server requires effective `workspace.manage`. Consent
explicitly covers workspace-wide retained storage, including private scopes,
without message or file content. Changing the capability version invalidates
the remembered approval fingerprint. Existing identity, code freshness,
revocation, context and signer checks continue before and after reads.

Storage is current retained inventory, independent of the activity range. The
host validates the existing activity report separately, then the bounded
`workspace-storage-v1` structure: unique generic group/metric IDs, safe integer
values, bytes/count units, method, estimated/actual/unavailable status, scope,
snapshot time and caveats. New metric IDs within these bounds need no host
update. Unavailable measurements remain null, never zero. PostgreSQL logical
workspace estimates and metadata/history subsets do not represent physical database
size; deduplicated recorded object metadata does not measure provider billing.
The cartridge owns metric labels and rendering.

An HTTP 403 from this version 2 report request yields `forbidden` with
`Workspace management permission required.` Version 1 error handling is
unchanged. Other failures remain unavailable or invalid; no alternate endpoint,
arbitrary URL, SQL, provider request or credential is exposed to the frame.

Shared synthetic fixtures in the core test suite cover the full report, storage
extension and bridge errors. Source support does not activate the backend API,
publish a new File version, or install an app on a user's device.
