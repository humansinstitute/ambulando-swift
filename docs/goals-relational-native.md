# Native Goals storage

`GoalsService` is the application repository for the personal Goals controller,
mention search, editing and discussion reference resolution. SQL and the shared
wire specification belong to [shared/goals-relational](../shared/goals-relational/).
The native client signs requests as the connected user. It never receives an app
signing key or installs schema/policies.

The generic NStack `native-v1/status` operation controls storage selection. Before
activation, the retained File implementation remains available. An active server
authority selects normalized SQL. A frozen authority refuses changes and preserves
the last verified content. `goals_authority` records application migration
provenance; it cannot independently select a canonical writer. Source Files and
their immutable versions remain retained after activation.

`GoalsRelationalRepository` reads authority provenance, goals, checkpoints and
associations using the same server generation across every table/page and a final
verification query. A generation conflict restarts the whole snapshot, up to three
attempts. No partial list becomes the cached snapshot. The row adapter verifies
workspace, channel, owner, parent identities, positive revisions and complete child
ordering before materializing the app model. Known facts come from normalized
columns; unknown extensions survive at all three levels.

The original File UUID remains `GoalDocument.id` and the identity used by saved
`mention:file` tokens, URLs and `goal_file_id` associations. SQL-created goals use
the same UUID identity convention without creating a new canonical File body.
The compatibility `FileRecord` shell has no storage object or File version.
`GoalDocument.storage` distinguishes SQL revisions from immutable File version
UUIDs, including after encrypted cache restoration. Chat association record IDs
remain thread UUIDs, distinct from channel/root-message mention syntax.

Each save sends a parent CAS, normalized child changes and append-only normalized
history together in one atomic batch. Newly added references are checked through
their own typed record routes. Existing unavailable references remain intact; a
link never grants access. A stale parent refuses the save and asks for refresh.
Focus reorder retains its existing explicit partial-progress reporting across
separate goal saves.

Before sending, the exact mutation body (including operation UUID, generated Goal
UUID and full draft) is sealed in the existing identity/backend/app/workspace cache
boundary. An ambiguous response retries only that exact request. Recovery after
relaunch replays the same operation; an unchanged create form receives the original
created UUID. A different intent waits for recovery and refresh. Per-service save
serialization prevents simultaneous UI saves overwriting the pending slot. Pending
requests remain sealed across channel revocation so restored access can reconcile
an uncertain commit; they do not confer permission to replay.

The persistent authority stamp prevents a missing namespace or transport outage
from restoring legacy write authority after an observed cutover. Cached content
is read-only evidence, never a write grant. Known access removal invalidates the
affected channel's display cache; transient failures retain it. Existing signer,
runtime, backend-owner, app and workspace cache guards remain in force.

Validation lives in `GoalsRelationalTests` plus the existing Goal format, edits,
wire, mention, discussion, focus and encrypted-cache suites. Backend activation,
exact source migration and rollback reconciliation are managed separately; a
successful fixture test or local Mac build does not establish live activation or
installation on a user's Mac.
