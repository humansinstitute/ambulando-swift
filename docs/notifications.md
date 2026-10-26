# Notifications (iPhone, iPad, Mac)

The native apps show Tower's durable per-recipient notification inbox (`org.wingman.nstack.notifications` v1, item schema
`org.wingman.notification.item` v1). The inbox is Tower's: this app reads it, changes a person's own read/dismiss/archive
state through it, and never invents notifications. Wire shapes live in one adapter,
`AmbulandoCore/Sources/AmbulandoCore/Notifications/NotificationsAPI.swift` (plus `NotificationPreferences.swift`).

## What a person sees

- A **bell** in the toolbar of every section (and ⇧⌘N on the Mac) with the unread count of the selected workspace.
- **Notifications** sheet: Unread / All / Archived, a category filter, *Mark all read*, swipe or menu to read/unread, archive and
  dismiss (with Undo), pull to refresh. Tapping opens the thread, channel, task, document or file; anything this build has no
  screen for (another app's `app_object`, a newer schema version) opens a plain detail card.
- **Settings › Notifications**: whether Tower has an inbox, unread count, when the inbox started, one "show in inbox" switch per
  category from Tower's registry (mandatory ones are locked), and an honest line that alerts outside the app are not available.
- A Tower without the inbox (404/501) shows "not available on this Tower"; Deck's Inbox and Needs You are untouched and keep
  their own view-state semantics. Notification read state never writes a resource view, and a resource view is never written by
  reading, dismissing or archiving a notification.

## How it works

| Piece | File |
| --- | --- |
| Item/change/count records, tolerant parsing, plain-text cleaning, generic targets | `NotificationRecords.swift` |
| Routes: `items`, `changes`, `counts`, `PATCH items/:id`, `bulk`, `categories`, `rules` | `NotificationsAPI.swift`, `NotificationPreferences.swift` |
| SQLite schema 7 (`notification_items`, `notification_sync`), pending overlay, tombstones | `NotificationStore.swift` |
| Keyed sync job `notifications:<w>` (snapshot then replay), archive on demand | `NotificationSync.swift` |
| Offline-safe actions through the durable write queue | `NotificationActions.swift`, `WriteSender.swift` |
| Sample-data Tower (Studio has an inbox; Lab has none) | `Sample/SampleNotificationTower.swift` |

- **One sync owner.** A `notification_item` event on the existing events stream only *hints*: `EventPlan` schedules the same keyed
  job that foreground resume, reconnect, background refresh and pull-to-refresh already use. There is no timer or loop of its own.
- **Snapshot then replay.** The first `items` page fixes `S = head_seq`; pages are stored with their cursor, so a long inbox
  continues across jobs (a page budget per job) under the original `S` and generation. Only the last page makes the inbox *ready*,
  removes rows the listing did not mention and sets `local_seq = S`; then `changes?after_seq=` is replayed idempotently and
  `local_seq` becomes the last applied `through_seq`. `410 reset_required` or an expired cursor lists again; unsent local changes
  are kept. Tower's `counts` win over a locally derived count when nothing is waiting (one re-listing, rate limited).
- **Partitions.** The device holds exactly the `inbox` partition; archived items only after the person opens Archived (then kept
  current by `changes`); dismissed items are never kept. A tombstone deletes the row and its text.
- **Acting on what was seen.** A tap sends the *rendered* item's `row_version`, `change_seq` and `observed_change_seq`. If newer
  activity folded in meanwhile, Tower answers 409 and read/dismiss/archive is **not** applied to it (the person is told);
  unread/undismiss/unarchive, and conflicts that changed only state elsewhere, are re-applied once with a new `mutation_id`.
  Two quick actions on the same card chain from the first result. `mutation_id_reused` is a rejection, never silently retried.
  *Mark all read* is bounded by the sequence the screen was drawn at (`up_to_seq`).
- **Security.** Reads use the unlocked identity or the existing policy-limited background credential (GET only); every change goes
  through the write queue, which signs only while unlocked. Items cache only plain text (bidi/control characters removed); an item
  without access never keeps producer text. No notification is ever authority to act.

## This app's view (contract v1.1)

Every read (`items`, `changes`, `counts`) and `bulk` is asked for as `client_app_id=ambulando`, a presentation filter and never an
access boundary. The per-category switch in Settings writes only Ambulando's own inbox rule: it hides items from this app's views
and leaves the shared item and every other app unchanged; reading stays shared. The snapshot's `rules_revision` is stored and sent
with `changes`; a `410 reset_required (rules_changed)`, or a different revision seen in `counts`, lists the inbox again. Rules are
written all-or-nothing with each key's `expected_row_version` (0 only when absent); on `rules_conflict` nothing is written, the current rules are adopted
and shown with a notice, and the person's next explicit choice is sent with a new `mutation_id` (never silently re-applied);
`mutation_id_reused` is a rejection. Pages of one listing that disagree on `rules_revision` restart the listing. `default` keeps its row.

## Limits (this build)

- No alerts outside the app: Tower has no alert sender, installation/transport registry, quiet hours or APNs route yet, and this app
  has no push setup. Settings says so; nothing is claimed or sent. `Push/` keeps the UI-free APNs groundwork unconnected.
- Mac: compiled and launched in sample-data mode; the shared views are exercised by the iPhone sample UI tests.

## Validation

`NotificationTests.swift` (core, a fake Tower with CAS, folds, tombstones, resets, long listings, offline retries, locked identity)
and `AmbulandoUITests/NotificationsUITests.swift` (sample data on the dedicated *Ambulando Test iPhone*). Sample results do not
validate a live Tower.
