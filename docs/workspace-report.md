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
