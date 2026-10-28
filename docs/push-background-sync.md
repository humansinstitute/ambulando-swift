# iPhone push cache refresh

Build 33 adds an opportunistic cache refresh when iOS delivers an APNs fetch callback. The existing visible alert and tap
routing remain intact. Receiving a push does not open anything, change the current workspace, mark content read or send
pending edits. Screens continue to read the SQLite cache through live queries; drafts and navigation keep their existing
storage and ownership.

## Delivery contract

Tower's `notification-apns.ts` / `notification-alerts.ts` sender must add `aps["content-available"]=1` for the **recipient**
`client_app_id=ambulando`. The existing `fd` v1 routing envelope, generic visible copy, sound, grouping and alert/priority-10
headers remain. Other recipient apps retain their prior payload. The paired Tower contract lives in
`docs/contract/notifications-push-v1.md`. Source compatibility does not establish deployment or APNs delivery.

The app enables `remote-notification` alongside scheduled `fetch`. Its completion-handler delegate parses only ids,
then starts a fixed 25-second window including cold startup. Work is bounded to five distinct targets per window;
duplicates share a fetch, and a distinct event for an active target requests one rerun without extending the deadline.
Expiry cancels the owning read invocation and completes each callback once, even if startup finishes later. Scoped
`SyncEngine.perform` cancellation preserves a newer foreground rerun of the same key and unrelated writes.

## Local progress and recovery

The stored Tower connection, signer and workspace list determine access. A push origin is never fetched; its Tower identity
hint is checked using the existing router. Foreign workspaces/origins and the wrong signer do not trigger reads. All reads
use the existing NIP-98 transport, engine slots, row-version upserts and serial writer. Named tasks/documents use the event
materialiser; conversations use the existing thread/channel reader, including replies. Notification inbox hydration/deltas
use the existing snapshot/sequence path. No notification state action or outbox sender is invoked by push refresh.

Event polls apply up to five pages and advance only the stored cursor following successfully materialised pages. Pushes
never adopt `change_seq` as a cursor. If no event cursor exists or Tower rejects it, the named resource can still refresh;
full gap hydration waits for the normal foreground path. A delta page needing independent discovery, directory, canvas
or notification jobs is also left replayable for foreground rather than starting work outside the push window. A timeout keeps successful pages and leaves the remainder for
another wake. Opening, unlocking, and network return schedule event/notification catch-up for every saved workspace without
selecting it. These iPhone lifecycle triggers coalesce with the existing SSE and sync jobs.

## Locked phone and platform limits

The SQLite directory uses `completeUntilFirstUserAuthentication`. Before the first unlock after reboot, protected data or
credentials can be unavailable and the push cannot fetch. The normal session credential is
`WhenUnlockedThisDeviceOnly`. A cold launch on a locked phone needs the user's existing **Refresh while locked** opt-in:
its `AfterFirstUnlockThisDeviceOnly` credential is restricted by the app to reads at the stored origin/workspaces. This
change neither enables that option nor weakens key protection. Manual Lock now revokes it and cancels the push window.

Apple controls delivery and execution. Background App Refresh settings, power/network conditions and system scheduling
can defer or suppress work. Force-quitting prevents automatic background relaunch. Foreground catch-up is required;
background freshness is never guaranteed. Simulator delivery cannot establish real APNs/locked-device behaviour.

Primary platform references:

- [Apple fetch callback and its execution allowance](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:))
- [Apple background update payload, including visible alert keys](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/CreatingtheNotificationPayload.html)
- [Apple background push scheduling](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## Validation

Focused synthetic tests cover duplicate/new events, fixed deadlines and late completion, cursor persistence, failed-delta
recovery, cold/invalid cursors, foreign origin/workspace/signer refusal and preservation of unrelated/foreground work on
expiry. Existing background-reader, notification, chat, sync and tap suites supply regression coverage. Build/install,
simulator and real-device APNs evidence belong to the release task; a source build number alone proves none of those.
