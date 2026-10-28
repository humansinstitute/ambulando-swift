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

## Alerts outside the app (iPhone and iPad)

A visible APNs alert reaches the device while Ambulando is closed. It is a *prompt to sync*: the lock screen shows generic text
("New activity") and a few ids; opening it fetches the inbox item again with the person's own credentials.

- **Entitlement and signing.** `Config/Ambulando.entitlements` carries `aps-environment`. Automatic signing registers the explicit
  App ID `studio.otherstuff.ambulando.native` with Push Notifications and an `aps-environment` profile (verify with
  `codesign -d --entitlements :-` on the built app). Xcode device builds are `development` (APNs sandbox); distribution export
  rewrites it to `production`. At run time the app reads the environment from the embedded profile (`PushEnvironment.resolve`), so
  a token is registered for the host that issued it. The Mac app has no push entitlement (a Developer ID profile with push needs
  portal work) and says alerts are unavailable there.
- **Enabling.** Nothing is requested at launch. **Settings › Notifications › Enable Notifications** shows the system prompt (alert,
  sound, badge); a refusal is shown as "Blocked in system Settings" with an Open Settings button. Turning alerts off in system
  Settings later withdraws the registration on the next reconcile.
- **Registration** (`Push/PushCoordinator.swift`). A stable installation id and the device token live in the app store (never
  logged or shown). For each workspace the app `PUT`s `…/notifications/apns-devices/<installation>` with `client_app_id=ambulando`,
  `platform`, `permission_state=granted`, `environment`, `bundle_id`, a 7-day lease. Leases renew at half-life on launch, unlock,
  foreground and workspace-list changes (no timer). Uploads are signed by the unlocked identity only: while locked the token waits.
- **Truthful status.** Only an explicit `delivery.ready=true` reads "On". `ready=false` (`provider_not_configured`,
  `environment_not_enabled`, `permission_not_granted`) and a Tower that sends no `delivery` field read "Waiting for Tower";
  **Check again** renews the registration now (unlocked only) to read the current state instead of waiting for half-life. `404/501` shows "Not available on this Tower" and is retried at most hourly.
- **Withdrawal.** Disconnect, Remove identity, Turn off alerts, a signer change, a removed workspace, or alerts denied in system
  Settings `DELETE` the registration. A revocation that cannot be signed (locked) or sent is kept and retried when its signer is
  unlocked, and dropped when the lease has ended (Tower stops delivering to an unrenewed lease by itself). The installation id is
  rotated on every withdrawal and signer change because Tower binds an id to its first actor (`409 installation_owned`); owed
  revocations keep the id they were made under. A token held by another account is reported (`transport_owned`), never taken.
- **Tap.** `UNUserNotificationCenter` delegate is set before launch finishes, so a cold tap is delivered. The payload (`fd` v1) is
  parsed strictly and checked by `PushRouter` against the connected Tower and workspaces: the payload's `tower_service_npub` is matched to the
  connection's stored Tower identity (so a pinned or alternate address for the same Tower still matches; a different Tower is refused), otherwise the origin text must match. The payload's origin is never fetched. Locked: the tap is held in memory
  (ids only) until unlock, then decided again. Open: the workspace is selected and, if the alert names an
  inbox item, that item is read fresh from Tower (`GET …/notifications/items/<id>` with no query, one signed request through the sync owner,
  never the local cache). Only an item Tower still grants opens, through the ordinary notification route (an external app's
  object shows a plain card). 404/403, a tombstone or `access:"unavailable"` shows a neutral notice; a failed check (network,
  locked) opens nothing and does not fall back to a cached copy or title. An alert with only record ids opens that record, whose
  own load checks access. Opening marks the notification read at the fetched sequence, never earlier.
- **Foreground.** An alert for the thread, task or document already on screen is not shown as a second banner; others use the
  system alert channel.

## Push cache refresh (iPhone/iPad build 33)

The remote-notification background mode and fetch callback request a bounded cache refresh alongside visible alerts.
Tower must send `content-available=1` for the Ambulando recipient. A cold locked launch needs **Refresh while locked**;
iOS can defer or suppress execution, and foreground/reconnect catch-up remains required. Receiving a push never marks
notifications read or navigates. See [the execution and recovery contract](push-background-sync.md).

## Limits (this build)

- Alerts outside the app need a Tower that has an APNs provider key: until then the registration is accepted but Tower reports
  `delivery.ready=false` and Settings says "Waiting for Tower". No quiet hours.
- Mac: compiled and launched in sample-data mode; the shared views are exercised by the iPhone sample UI tests.

## Validation

`NotificationTests.swift` (core, a fake Tower with CAS, folds, tombstones, resets, long listings, offline retries, locked identity)
and `AmbulandoUITests/NotificationsUITests.swift` (sample data on the dedicated *Ambulando Test iPhone*). Sample results do not
validate a live Tower.
