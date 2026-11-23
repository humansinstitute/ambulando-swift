# Generic File apps (Mac107 / iPhone108)

A generic v2 napplet is an existing NStack HTML File with one declared capability
and an explicitly bound existing resource. Apps → Add napplet offers locally
loaded HTML Files or a File link/UUID. The picker is not complete workspace
discovery. Verified manifest title and local text/emoji icon supply the launcher;
app IDs never confer authority or select a host implementation.

Installation uses your existing personal File pin. Uninstall removes the pin,
keeping code, data and history. Every launch rechecks the File ACL, current
immutable HTML head, MIME, size, SHA256, manifest and bound resource. Shared code
uses normal File access; private JSON must belong to your single-person self-DM.

Supported capabilities are `private-json-file@1` (bounded object read and optional
whole-object CAS save) and `workspace-aggregate@1` (fixed authorized workspace
report, ranges 7d/30d/90d/all and top ten). Save requires both a manifest save
declaration and current explicit write permission. A present top-level flag wins; only its absence permits an explicit boolean File flag fallback. No automatic resource
provisioning, rebinding, schema migration, arbitrary network, SQL or signer API.
Existing v1 tracker/report adapters, domain validation and approvals remain separate.

Approval is device-local in a separate v2 namespace, bound to verified code,
manifest, resources, context and effective grant. Check for update reopens the same
logical code File. Changed code or access asks again; unchanged reopen remembers
approval. A code-only revision does not change the JSON File or its history.
New app IDs and binding names require no host rebuild. New host capabilities can
require a runtime update.

Native runs inline HTML in a nonpersistent opaque sandbox, blocks network and
navigation, checks exact source/origin and a 32-hex session nonce, bounds replay
IDs to 10,000 and permits one operation at a time. Busy requests are ignored
without consuming IDs. A validated initial read arriving during an authority check
waits for that check with its original deadline; writes are never queued.
Operations have a 45-second deadline; focus and 30-second
authority checks preserve healthy draft DOM and destroy it on authority loss.
Private JSON/aggregates/drafts remain memory-only outside NStack storage.

The portable specification and golden fixture are owned by the web runtime at
`docs/design/generic-napplet-v2.md` and `tests/fixtures/napplets/generic-v2.json`.
Swift's copied fixture is under `AmbulandoCore/Tests/AmbulandoCoreTests/Fixtures`.
Focused tests cover canonical JSON, exact envelopes, receipts, limits, Unicode
keys, authority, CAS conflicts and uncertain acknowledgements. Source/build and
synthetic native tests do not establish installation or real-account acceptance
on Pete's devices.
