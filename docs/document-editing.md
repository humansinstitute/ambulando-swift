# Editing and recovering documents

Mac, iPhone and iPad open supported documents in edit mode when unlocked. Archived documents and unsupported stored formats remain in the reader. Tower enforces edit permissions and leases; a denied lease makes the editor read only. Selecting text exposes a floating comment icon at the right of the editor, beside the last visible selected line. The 44-point action stays within the keyboard-visible viewport and follows scrolling and resizing; showing or clearing it adds no layout space. It works by touch on iPhone/iPad and by pointer or Option–Command–M on Mac. Escape dismisses it; a cleared, invalid or offscreen selection hides it. Mac reading mode also offers a native selection comment icon. It captures the selection before native focus changes and saves only when the person requests a comment, then binds the anchor to the saved version. Actor tagging and comment submission use the existing composer and durable write queue.

On Mac, editing authority, pending-save and last-sync messages, saved versions, takeover and recovery actions live
above Comments in the right panel. The panel collapses to a thin comment rail; its status icon exposes the current
save/error state by tooltip and accessibility label and opens the full controls. A selection comment opens the panel.
Collapsing the panel deliberately widens the page; selecting or clearing text does not change panel width or layout.
iPhone/iPad retain their compact status and comments sheet. The iOS sheet observes the captured anchor before its
first presentation, so the composer immediately shows the selected quote.

Active native editors checkpoint changed documents every minute. Local SQLite drafts remain durable while offline. The existing `document_edit_session_v1` contract controls explicit takeover: preserve local divergent work as a typed Tower recovery, acquire against the observed lease, and load the latest canonical body and title. If the other lease has expired, the same explicit action starts a fresh session using the existing acquire contract. A superseded editor never regains authority through autosave.

On a materialised head change or foreground return, the editor checks the latest saved head. Unchanged local work follows that head. Meaningful differences are exact title differences or semantic document differences: text (including whitespace and deletions), marks, attributes, node order and unknown content fields count; JSON object-key order and generated Markdown/block fields of a rich document do not. No character-count threshold or automatic merging is used. Divergent snapshots must be retained by Tower before their matching local draft is retired. An offline failure leaves the page and local draft intact.

A small saved-versions icon opens latest and previous snapshots. Keeping a previous snapshot uses Tower's recovery promotion command with the reviewed head row version, body hash and valid lease. A stale choice fails and retains both versions; reopening refreshes the choice. Dismiss targets only the selected recovery and leaves canonical content and stored recovery bytes intact. Closing or keeping latest leaves previous versions recoverable. The chooser previews stored text without computing diffs or modifying stored bytes.

Recovery commands live in `DocumentSaver`; canonical responses materialise into SQLite, and the views observe the store. No Tower route or schema changes are required. Web retains its existing recovery/promote/discard flow and save cadence. Android is unchanged. Background-suspended iOS cannot guarantee minute checkpoints; physical device and real-account acceptance must be reported separately from fixture and API checks.


The isolated geometry regression uses the built native editor in macOS WebKit:

```sh
scripts/build-board-editor.sh
swiftc -parse-as-library scripts/tests/document-comment-webkit.swift -o /tmp/document-comment-check
/tmp/document-comment-check "$PWD/BoardEditor/dist"
```

It checks repeated selection/clear/type without document or scroll movement, exact anchor capture before focus changes,
scroll visibility, window resizing, keyboard viewport bounds and snapshot/reopen. `DocumentInlineUITests` checks actual
iPhone touch selection, keyboard bounds, stable native toolbar/editor frames, anchored comments/replies and relaunch.
The isolated Mac document workflow checks stable native toolbar/page geometry and the existing save/comment/recovery pipeline.
These sample checks do not establish installed-device or authenticated live acceptance.
