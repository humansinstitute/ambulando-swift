# Goal discussions (Mac source build 144)

Goals can start discussions, retain useful outputs and keep key references close to the aim. This guide describes
implemented source behavior. A successful source test or local build does not establish installation on another Mac,
live NStack permissions, active Autopilot agent context, or iPhone/web acceptance.

## Starting and recovering a discussion

**Discuss goal** creates a native thread with a durable reference to the Goal File. It uses the goal's saved default
channel. Without a default, the user chooses an accessible channel; that one-off choice does not change the default.
An unavailable saved default is disclosed and requires an explicit replacement or change. The client never falls back
to the currently selected channel. The channel, scope, goal state and original workspace/account are checked before
creation; NStack enforces the actual write permission.

Thread creation has no generic idempotency guarantee. Before submitting, the app stores a local receipt bound to the
connection, workspace, goal, original channel and request ID. If the result is uncertain, **Find discussion** searches
that original channel for the saved request. It does not repeat the create request. A missing, denied, duplicate or
incomplete result keeps the receipt. After a lookup attempt, an explicit **Start a separate discussion** confirmation
can retire it; the earlier thread is never deleted. Receipts survive client-store reopening.

## Pins and associated work

**Pinned references** holds selected existing Docs and Files, including whiteboards. Pins open the original native
record. Unpinning removes only that reference; it does not delete, move, duplicate or change access to the source.
Pins remain separate from the goal's general associated work, and an inaccessible pin remains removable.

Associated work combines explicit goal links with accessible synchronized threads, Docs and Files carrying the goal
reference. An automatically associated output stays connected through its original record metadata. Removing a manual
link does not remove this provenance. Record titles and locations come from the current source records, and access
loss, deletion or an unavailable parent channel/scope prevents opening their content.

The discovery view is local to the selected workspace and depends on its synchronized records. It does not imply a
complete server-wide inventory. More than 500 matching records of one type produces an incomplete-view error rather
than silently hiding the overflow.

## Creating outputs in a discussion

The thread artefact browser offers creation of a Doc, whiteboard or HTML artefact in that discussion's channel. Before
enqueueing, the client resolves the authoritative thread and captures its canonical primary goal reference and source
thread ID. The durable queue retains that original destination and association across retries; a later selection or
explicit mention cannot redirect it. Target-channel access is checked by NStack when the record is actually created.

Ordinary composer uploads remain storage attachments on their original message. They are connected through the
associated discussion, without creating duplicate File records. Editing a sent text attachment creates a native
lineage File on its first edit; that File inherits the original message's thread goal. Existing lineage Files and
later versions retain their original association. If the original message returns 404, editing remains supported
without inventing a goal; other source access failures retain the local edit.

## Existing contracts and access

Goals remain ordinary versioned Files using `application/vnd.ambulando.goal+json` and `ambulando.goal` schema version 1.
The additive fields are `default_channel_id` and `pinned_refs` (Doc/File references in the existing link shape).
Absent values remain compatible with old goals; unknown goal and reference fields survive edits. The limits are
100 pinned references, 500 explicit links and the existing 256 KiB Goal File limit. Default-channel edits compare the
value the editor saw; pin/unpin are independent reference changes applied through the existing File revision check.

Native thread, Doc and File metadata carries only the association:

```json
{"ambulando_goal":{"version":1,"goal_file_id":"<goal-file-uuid>"}}
```

Created outputs also carry `source_thread_id`. This is application metadata over the existing native records, not a
new NStack endpoint, catalogue or permission. Native identities, revisions, comments, storage objects and assets remain
owned by their original channel. A readable thread may retain a canonical goal reference when reading the Goal File
returns 403; no private goal content, pin content or additional access is propagated. An accessible wrong-kind,
unsupported or missing goal is refused rather than treated as a valid context snapshot.

Agent context is carried by Autopilot. The chat's primary association and multiple explicit goal mentions are separate:
mentions supply additional context and never replace the primary goal. Authoritative goal and pinned-source reads use
normal ACLs. Goal context is descriptive data, never agent instructions or an access grant, and stays out of visible
message boilerplate. Agent-generated native outputs need the corresponding active Autopilot helper support.

## Validation and platform scope

The focused core tests cover format compatibility, default and pin conflicts, native reference discovery after store
reopening, workspace isolation, soft deletion, strict pending receipts, canonical metadata, unavailable goal reads,
bounded recovery, and text-lineage creation/retry behavior. Run from `AmbulandoCore`:

```sh
swift test --filter 'Goal|TextAttachmentTests' -j 2
```

Mac app build and native interaction checks are separate delivery gates. Pete receives Mac source through GitHub
`main` and builds locally; a pushed revision does not establish installation on his MacBook. Shared Swift source can
improve iPhone compatibility, but this feature's iPhone and web build/UI/device parity remains a separate acceptance
item. See [the base Goals format](goals.md) and [the parity matrix](parity-matrix.md).
