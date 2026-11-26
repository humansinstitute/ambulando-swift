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

## Shared thread membership (Mac source build 137)

The existing canonical thread metadata PATCH now stores
`ambulando_thread_artefacts: {"version":1,"items":[{"kind":"doc"|"file","id":"UUID"}]}`.
The same format is consumed by Android. It contains at most 32 distinct native record/type
identities; selection, pinned history, viewport, editor state and message dispatch snapshots
remain separate. Unknown formats prevent membership edits while ordinary Chat stays usable.

The header artefacts icon beside Pin opens the attached list and existing browser even when
empty. Unopened shared members fetch only authorized source metadata for readable titles;
they do not mount editors or enter Send context. New attachments accept nonarchived Docs and
registered whiteboard/HTML Files; other file mentions keep their normal viewer route. Existing
unsupported members remain removable without loading their content. Source ACL/revision/digest checks still apply
when opening and capturing context. A reference grants no source access. A duplicate add
focuses the retained editor without changing its historical revision.

“Remove from thread” removes only the shared association. “Close local view” retains that
association. Remote removal excludes the record from future Send, holds automatic Doc saving,
and retains the mounted editor/local recovery. The recovery menu permits viewing it and an
explicitly labelled source Save; removal itself never calls prepare/flush/publish. An already
dispatched source write may finish. Re-adding a detached record does not automatically resume
its recovery's publishing. Open recovery and use “Save to source and resume if attached”:
that explicit action saves and verifies the source, rechecks canonical membership, then resumes
normal editing/context only if the record is still attached.
Already enqueued requests and retries retain their immutable exact revision snapshot.

Each add/remove reads the actual canonical row version, preserves all unrelated metadata and
reconciles bounded definitive 409 conflicts. A lost response, 5xx or malformed acknowledgement
requires canonical readback. Satisfied intent is accepted. Unsatisfied intent on an advanced
version reports uncertainty rather than replaying against a new base; a retry on the unchanged
CAS base is safe. Store upserts reject older rows. Membership observes ordinary thread sync
and refreshes on entry/resume; there is no second event stream or view polling timer.

Migration supports only nonempty, source-verified local references while the canonical key is
absent. An initialized empty key remains authoritative, including after last removal. The old
Mac runtime did not persist its tabs to disk, so an upgrade cannot recover tabs that vanished
when the old process exited. Live retained tabs can migrate; a fresh process has no legacy
refs and does not initialize an empty key merely because that device has no tabs.

Mac137 validation uses synthetic authorized routes and independent stores. This does not claim
MacBook installation, live account interaction, or iPhone/web UI implementation. Shared core
remains available to those clients; their membership UI still needs its own parity work.

Mac137 validation passed 28 XCTest cases (including ten membership concurrency/schema/migration
cases and fifteen outbox cases), 43 Goals/board/context tests, and twenty Goals script tests.
The real AppKit/SwiftUI/WebKit synthetic fixture passed native picker/tab interactions, two-store
discovery, source Save before Send, hidden exact metadata, dirty remote detach/re-add/explicit
Save and resume, lazy unreadable and future-schema plain Chat, last removal, frozen request
preservation and initial-absent legacy migration ordering. Test and universal Release builds
are 137; this is local synthetic validation, not installation or live MacBook verification.
