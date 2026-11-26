# Mac thread artefact workspace (source build 134)

Use **Browse artefacts** (+) in the conversation header, including when there are no tabs
or the workspace is hidden. The + beside the workspace tabs opens the same native picker.
Search titles and filter Documents, Whiteboards or HTML. The picker defaults to the actual
conversation channel, independently of the global sidebar context. Its channel menu labels
the scope and channel and can show all authorised channels in the current workspace.
It reads at most 500 saved Docs and 500 Files in the selected channel (or across the
workspace for All channels) using the existing store queries and sync;
labels need no downloads. Only supported File types and discovered channels are included.
Locked, loading, empty, no-match and read failure states are explicit; Refresh retries the
existing list sync, whose failures remain visible. This is a saved-record picker, not a URL
or external web browser. Cancel leaves tabs and selection unchanged. Choosing a record
opens/focuses its real panel tab and dismisses the picker. Existing historical selections
stay pinned, including after closing and reopening a retained tab. Channel selection
restarts the bounded query; a workspace, connection or identity change dismisses the picker.

A Doc/File reference in an open Mac conversation also opens a retained workspace beside chat.
Chat starts at roughly one third of the available width. Drag the divider to resize it.
Compact type icons, bounded single-line titles, rounded selected backgrounds and an accent underline identify tabs. Close controls retain a predictable position; hover, keyboard focus and accessibility labels remain available. Tabs scroll horizontally; selection and window resizing reveal the chosen tab. The +, expand and hide controls remain outside the scroll area. Opening the same reference focuses its existing tab.
Expand the workspace, restore the split, or hide/reopen it without replacing the composer
or mounted editors. Closing a tab first saves its pending content; failures retain the tab
and explain how to retry. The optional separate-window action is not added to thread tabs.
The existing independent document/artefact windows remain available outside the workspace.

Whiteboards reuse BoardController and the bundled editor. HTML reuses the sandboxed review
view and version menu. Documents reuse the existing editor and canonical Doc history;
Refresh revisions loads a selector whose historical views are explicitly pinned and
read-only. Switching tabs retains editor/view instances. This does not add a catalogue,
change record identities, or grant access. iPhone/Android/web navigation is unchanged;
the desktop workspace and its context capture are a parity gap on those platforms.

## Send contract

Send removes editor focus, disables workspace interaction, flushes each open editor and
waits for successful canonical saves. Pending HTML source recovery is saved against its
original base. Pending whiteboard drafts are saved even when the selected view is a pinned
historical revision; that historical selection remains unchanged. Conflicts, offline saves,
missing versions and denied writes block sending, keep the chat draft and retain recoveries.
A denied whiteboard publish clears the unauthorized viewer but retains the local recovery;
reading it again still requires successful authorized loading.

The app then validates the captured selections and holds the barrier through durable outbox
insertion. The draft is separate from the generated context. Queue failure restores only the
original user draft; retries reuse the existing frozen request and idempotency key.

The visible and kind-33358-signed body contains only user text under existing trimming and
mention-token semantics. Generated prose/JSON is never appended. The existing generic message
`metadata.ambulando_artefact_context` carries schemaVersion 1 with workspaceID, channelID,
threadID, workspaceVisible, visibleRecordID and open references. Each reference carries kind,
recordID, revision, revisionKind, historical and the exact canonical SHA256 digest. File revisions
use immutable `file_version_id` UUIDs. Doc snapshots use `doc_versions.row_version` with a
required SHA256 digest of the full canonical snapshot bytes; a mutable head is insufficient.
No titles, binary assets, browser state or instructions enter the snapshot.

Context is validated against the captured ChatTarget before the atomic outbox write, stored
in an additive local column, and included in the frozen exact JSON request. Fresh NIP-98 headers
cover all request bytes including metadata. Retry never recaptures current tabs or routing.
Old queued bodies and signed requests remain unchanged, including pre-133 generated suffixes.
Discard/Edit restores the stored user body for new messages; old body content remains history.
No history migration or display heuristic hides user-authored JSON.

Limits: 32 unique Doc/File references and 16 KiB UTF-8 JSON per snapshot; UUID routing/record
keys, exact revision kinds, positive Doc revision and SHA256 syntax are checked. Missing or
invalid context blocks a new native enqueue, preserving the draft. Autopilot ignores malformed,
oversized or foreign-routing snapshots and retains human text. It compares routing to canonical
message fields, never lets payload fields select a workspace, change eligibility or grant access.
Only actionable Prompt snapshots appear in a separate untrusted dispatch section, in both
initial and rehydrated envelopes; historical metadata cannot bypass the history budget. That
section is bounded to the latest 16 snapshots / 64 KiB compact JSON with an omission notice.
All retrieval remains through ACL-checked exact-revision contracts.

NStack's existing generic message metadata contract needs no backend/schema change. Autopilot
must activate the corresponding source change to project this namespace; the old runtime stores
it through NStack but does not provide it to the model. Source/fixture tests do not establish
live receipt or authorized retrieval by a real account. No shared-service restart or MacBook
installation is implied. Android/web/iPhone transport capture remains outside this Mac fix.

## Validation

Core regressions cover final debounced input, exact saved versions, pinned history with
pending drafts, conflicts, offline/denied publishing, recovery retention and Doc snapshot
keys/digests. The isolated Mac test harness can be run with:

```sh
'/path/to/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacThreadArtefactsCheck
```

It uses real AppKit/SwiftUI/WebKit views with synthetic Tower routes. It exercises the native picker entry points, search/no-match, cancel, board/HTML opening,
pinned revision refocus, close failure retention and many-tab narrow layout. Its injected
network failure, sample records and synthetic editing peer are simulated inputs, not
live-account evidence. Send uses the actual native composer and synthetic Tower readback.
