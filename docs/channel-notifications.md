# Personal channel notification choices

Select a channel and open **Deck → Inbox ••• → Channel options → Your notifications → Mute except mentions**.
Channel options shares the existing Inbox overflow with its four Mark read actions; it adds no header or standalone row.
The Inbox title wraps when needed on narrow screens and at larger text sizes. Chat, Tasks, Docs and Files retain
the sidebar channel ellipsis, with a 44-point touch target. From pushed channels, return to Deck and choose the channel through
existing navigation. There is no additional universal toolbar or row. These shared iPhone/Mac settings are available to channel readers
without Manage permission. Direct-message channels keep their existing notification settings. The choice is
personal to the authenticated actor and workspace; it does not alter channel access, messages, unread activity or
any other notification category.

Tower owns push eligibility and the visible notification inbox. A muted channel suppresses ordinary `flightdeck.core`
`chat_thread` items; direct person mentions, comment tags, DMs, assignments and notifications from other apps keep their
existing independent category settings. This is not an override of a globally disabled mention preference. Clients
never infer mention eligibility from message-text substrings.

The Swift adapter uses the shared contract:

- `GET /api/v4/flightdeck-pg/workspaces/:w/notifications/channel-preferences` reads
  `{identity, channel_preferences: [{channel_id, mode, row_version}], rules_revision}`. Missing rows mean `all`.
- `PUT …/channel-preferences/:channel` sends `{mode: "all" | "mentions_only", expected_row_version}`. An absent key uses 0.
- `409 channel_preference_conflict` returns the current list; the screen adopts it and asks the person to choose again.
  There is no silent retry or overwrite of a newer device choice.
- `404` or `501` explains that this Tower does not support the control. Failed requests keep the last confirmed choice.

All requests go through `WorkspaceSync`, with existing reader/signer identity checks. The personal settings form reads
on opening and foreground return. Successful writes reset the local notification cursor and schedule its one keyed
sync job. Tower increments the existing `rules_revision`, so other devices’ notification sync jobs re-list and remove
ordinary entries and update the bell count. No notification read/dismiss/archive action is sent by muting.

Options presentation and notification results are bound to the connection, current identity, workspace and channel;
switching that boundary dismisses the current options sheet. Unlocking reloads the personal setting. Loading, update
progress, failed requests with Retry, unsupported servers and stale-write conflicts are visible in the form. Channel
management still requires existing Manage permission; opening options or muting grants no additional authority.

The sample Tower implements the same preference routes and persists its choices for UI automation. Core tests exercise
old-entry removal/count convergence, mention and other-channel preservation, unmute, saved-choice reload, stale writes,
and workspace/DM rejection. Simulator automation starts in the normal channel directory, opens Deck’s existing Inbox
overflow and checks reader/admin open → mute → close/reopen → saved value → unmute/reopen, channel isolation, linked
channel navigation, pushed-channel return to existing Deck navigation, workspace switching to an unsupported endpoint and accessibility
text sizing. The reader fixture advertises only
channel.read/workspace.read so the test cannot accidentally pass with Manage authority. Fixture checks
are separate from server integration, installed-app checks and actual push receipt.

Android follow-up: add the personal channel control against the same versioned routes and refresh its bell snapshot
when `rules_revision` changes. Server push and inbox filtering are shared authority and do not require Android-specific
preference storage.
