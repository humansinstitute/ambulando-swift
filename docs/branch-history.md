# Branch history

A branch inherits the source conversation through the selected message, inclusive, followed by its own messages.
The existing Tower channel messages endpoint is requested with `thread_id` and `effective_transcript=true`.
All forward pages are read before replacing local membership. An interrupted read keeps the previous membership.
Canonical rows retain `owning_thread_id` (falling back to `thread_id`); attachments and unknown raw fields survive.
No parent or child record is rewritten to copy history.

SQLite schema 10 adds `thread_membership`, scoped by workspace and effective thread. It references existing messages;
message deletion cascades, and a thread deletion removes its memberships. Existing messages, threads, credentials,
drafts and pending writes are retained. Parent refreshes update canonical rows without changing membership and
notify open descendant conversations of changed inherited rows. Live child messages remain visible before a
membership refresh. The store only caches membership returned by Tower; it grants no additional visibility.

The thread view reads lightweight complete message IDs and materializes a 50-row body page. Its existing
anchor/fallback behavior preserves reading position. Earlier/newer navigation can reach beyond 500 messages;
header menu excerpts remain bounded to 500. The active thread is passed separately to message actions:
inherited rows cannot edit, delete or react, while copy, attachments and branch navigation remain available.
Nested branches use that active thread and the exact selected message ID. Outbox routing and inherited agent
recipient behavior are unchanged; viewing history creates no send or agent instruction.

`BranchHistoryTests` covers exact prefix membership, excluded later parent rows, nested inherited selections,
canonical parent refresh, database reopen, 620-message bounded pagination, effective forward-page requests,
ownership and attachment preservation. `MessageFlowTransportTests` covers the branch request and inherited
agent routing. Local stand-ins do not establish correctness of Tower's stored lineage or an agent's transcript.
Android parity is deferred; its separate follow-up must implement the same membership and read-only behavior.

Release verification must distinguish signed artifacts, installation readback and authenticated real-device
acceptance. Never repair a stored branch cutoff or delete user conversation records as part of a client update.
