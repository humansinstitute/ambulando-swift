# Mac thread artefact workspace (source build 132)

A Doc/File reference in an open Mac conversation opens a retained workspace beside chat.
Chat starts at roughly one third of the available width. Drag the divider to resize it.
Labelled tabs scroll horizontally; opening the same reference focuses its existing tab.
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

A labelled JSON block is included in the existing signed message body. It contains native
Doc/File IDs, exact revisions, historical flags, the selected tab, actual workspace visibility,
and routing captured from the composer's ChatTarget. File revisions are immutable version
UUIDs. Doc history uses the supported `/docs/:id/versions` snapshot `row_version`; a matching
full envelope must exist, and its SHA256 digest accompanies the reference. A mutable head
row alone is not sufficient. No binary assets, titles or browser state enter the context.

The block is descriptive, untrusted context, never instructions or an access grant. Agent
retrieval must use ordinary ACL-checked contracts and must not silently substitute latest.
Autopilot's existing direct-chat prompt projection includes message bodies; arbitrary new
metadata is not relied upon. Source inspection and synthetic tests do not establish receipt
or exact-revision retrieval by a real account/agent. That authenticated acceptance check
remains required, as does testing on Pete's MacBook after pulling and building the source.

## Validation

Core regressions cover final debounced input, exact saved versions, pinned history with
pending drafts, conflicts, offline/denied publishing, recovery retention and Doc snapshot
keys/digests. The isolated Mac test harness can be run with:

```sh
'/path/to/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacThreadArtefactsCheck
```

It uses real AppKit/SwiftUI/WebKit views with synthetic Tower routes. Its injected network
failure and programmatic tab opening are simulated inputs, not live-account evidence.
