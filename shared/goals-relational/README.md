# Ambulando normalized Goals

This directory is the canonical app-owned PostgreSQL schema, mapper, transport and migration tooling. NStack owns generic native-v1 scope, grants, CAS, receipts, snapshots, source fences and authority. Source presence does not activate a workspace. Production execution belongs to the reviewed manager candidate.

`goals.id` is the original File UUID, represented as text for the generic table contract. Checkpoints retain their string identity and explicit position. Associations separate ordered links and pins; chat `record_id` is a thread UUID, never a `channel#root` mention. Default discussion channel is a scalar preference. Unknown extensions are JSON **text** objects, preserving arbitrary numeric lexemes across server JSON decoding; known facts are columns/child records. Presence metadata retains absent/null distinctions. Original Files and immutable File versions remain retained.

`001-goals.sql` is a schema template. `deployment.mjs` renders only a verified allocated namespace, qualifies foreign keys and table names, and computes the exact rendered checksum. Policies use immutable scope, parent CAS, append-only history and manager-only provenance. Every table has a C-collation scoped keyset index. Deferrable child-position uniqueness permits atomic reorder while enforcing current-format count bounds.

The authoritative writer switch is generic native-v1 `/status` and `/authority`. `goals_authority` contains app schema/provenance evidence only; it is never a second writer switch. Clients reject unknown contract/schema versions before editing. Query and status POSTs are reads and must not wait for write readiness. Namespace outage does not revoke cached content or authorize a legacy fallback after SQL authority was observed.

A concrete production candidate uses `plan.mjs`: fence source creation **and** mutations first, capture complete exact source heads/hashes/history pointers and grants, read staged normalized rows, then seal deterministic requests. A changed head reconciles the same Goal UUID using CAS and new immutable history/provenance. Saved sealed batches are replayed unchanged after lost responses. `operations.mjs` executes the native-v1 staging and activation requests, checks post-fence source equivalence, verifies current rows plus normalized recovery history, and activates with generation/fence CAS. No production command runs implicitly.

Recovery after SQL edits freezes SQL first and uses `exportRecovery` to save a verified archive of every normalized revision outside the fenced original Files. The archive includes the complete normalized snapshot, current authority/generation and exact export hashes. Original Files stay fenced. Recovery uses reviewed SQL-native restore or forward repair; this tooling never unfreezes stale originals. An archive alone is not a completed repair.

Run pure tests with `node --test shared/goals-relational/*.test.mjs`. To include PostgreSQL, set `GOALS_TEST_DATABASE_URL` to an isolated fixture and `GOALS_TEST_POSTGRES_MODULE` to the installed postgres module entry if it is outside normal module resolution. Tests create/drop only a unique owned schema. Existing agent format/link tests use `bun test scripts/tests/goals-lib.test.mjs scripts/tests/goals-ops.test.mjs`.

The approved post-edit recovery path keeps PostgreSQL canonical: `recovery.mjs` verifies the complete frozen archive, chooses explicit historical goal revisions, and creates a sealed SQL-native forward-repair batch. Restored content becomes a **new** parent CAS revision with full normalized history; prior SQL history and original Files stay retained. Manager reviews the archive and repair, transitions frozen to manager-only staging, applies the identical receipt-backed batch, verifies every restored row, then reactivates with generation/fence CAS. No old source writer is re-enabled.

Operational CLI examples (private output paths must be ignored and untracked):

```sh
bun scripts/goals-relational.mjs inspect --tower https://HOST --workspace UUID --owner NPUB --app NPUB --channel UUID --schema VERIFIED_SCHEMA --out tmp/docs/handoffs/goals-inspect.json
bun scripts/goals-relational.mjs plan --input tmp/docs/handoffs/goals-inspect.json --out tmp/docs/handoffs/goals-sealed.json
bun scripts/goals-relational.mjs stage --tower https://HOST --workspace UUID --owner NPUB --app NPUB --channel UUID --plan tmp/docs/handoffs/goals-sealed.json --reviewed-sha EXACT_REVIEWED_SHA --evidence-dir tmp/docs/handoffs/goals-operations
```

`activate` uses the same reviewed plan/scope arguments. `export-recovery` requires frozen authority and writes the full hash-verified archive in the evidence directory. None of these examples establishes a live namespace or grants access.
