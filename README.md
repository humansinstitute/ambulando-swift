# Ambulando for iPhone and Mac (native)

A native SwiftUI client for Ambulando (Wingman Flight Deck) workspaces. It is a separate renderer, not
a WebView: screens draw from an on-device SQLite store, and one sync engine is the only owner of
network work against the existing Tower HTTPS + NIP-98 API. The web client lives in `../sol`.

- Architecture, inventory and budgets: [docs/architecture.md](docs/architecture.md)
- Feature parity with the web app (native / web / deferred / unsupported): [docs/parity-matrix.md](docs/parity-matrix.md)
- Work packages and commands: [docs/work-packages.md](docs/work-packages.md)
- **iPad layout and layout checks**: [docs/ipad.md](docs/ipad.md)
- **Mac app** (same core, desktop window, install on another Mac): [docs/mac.md](docs/mac.md)

## Layout

| Path | Contents |
| --- | --- |
| `Ambulando.xcodeproj`, `Ambulando/` | App target `studio.otherstuff.ambulando.native`, iOS 18+, iPhone and iPad; SwiftUI views, theme, assets |
| `AmbulandoCore/` | UI-free Swift package: identity vault and signing, Tower transport, SQLite store, sync engine, probes |
| `AmbulandoMac/` | Mac app target `studio.otherstuff.ambulando.mac`, macOS 15+, universal: window, sidebar, menus (compiles the shared `Ambulando/` views too) |
| `scripts/` | `mac-install.sh` (build, sign, install, package the Mac app), `build-board-editor.sh` (embedded board editor, needs bun), `source-bundle.sh`; `tests/mac-install-test.sh` (installer tests with stub tools) |

## Overnight feedback (iPhone/iPad build 31, Mac build 22)

- **One Messages view per channel.** The separate Threads pane is gone; a conversation with replies opens its thread.
- **Images open large** in a lightbox, from messages, documents and composer thumbnails: over the window on the Mac
  (zoom, Esc to close, Open in Preview), full screen on the iPhone and iPad (pinch or double tap to zoom, Share, tap
  beside the image to close). Quick Look had shown cached images as a blank document.
- **Wider composer.** Photo, files and mention are stacked on the left; Hide keyboard sits above Send.
- **Images stay where you put them.** Pasted and picked images keep their `![name](storage://…)` Markdown in the text at
  the caret, so they can be moved; the thumbnail above previews and removes them.
- **Threads never open blank.** iPhone/iPad threads use the Mac's measured 50-message pages (Earlier/Newer replies), so
  a reopened thread shows exactly where it was left.
- **Canvas.** Mac: each canvas in its own window. iPhone: the canvas fills the screen with Back and its controls at the
  bottom. Editing adds text, shapes, arrows, lines, frames, groups and new whiteboards; elements can be moved, resized,
  restyled, edited, arranged, duplicated and deleted. The Mac's Add to canvas and Board items lists show their rows again.
- **Thread menu in the header** (as on the web), beside pin, full screen and close: Get it done and Copy message for the
  first message, Autopilot Link, FD Ref (`@[Chat thread](mention:chat:<channel>#<root message>)`), and Delete message
  for its author.
- **`@` finds more than people:** documents, tasks, conversations, channels and scopes, looked up in the local database as
  you type (web prefixes such as `doc:` work), inserted as the web's reference tokens with pills.

Details and the remaining gaps: [parity matrix, Overnight feedback](docs/parity-matrix.md#overnight-feedback-iphoneipad-build-31-mac-build-22).
These are review builds on sample-data tests; they have not been checked against a live Tower.

## Composer draft ordering (iPhone/iPad build 29, Mac build 19)

Clearing an unsent draft now takes precedence over delayed reads of its older saved text. Newer external Edit
restores remain supported. The Mac channel Messages fixture covers repeated button/Return sends, incoming sync,
resizing and post-send typing. The reported real-account channel beachball has not been reproduced; this draft
ordering fix is not a confirmed remedy for that hang. These builds are for local review and are not activated.

## Notifications (iPhone/iPad build 28, Mac build 18)

- A bell with the unread count opens Tower's durable notification inbox: Unread / All / Archived, category filter, read, unread,
  archive, dismiss with Undo, *Mark all read*, and open the thread, task, document or file (a plain card for anything else).
  Settings › Notifications shows the inbox state and per-category inbox switches. Read state is shared with other apps and
  separate from Deck's Inbox and Needs You. Alerts outside the app (APNs) are wired on iPhone and iPad and need a Tower with an APNs provider key; Settings reports the real state. See
  [docs/notifications.md](docs/notifications.md). Build 27: a listing that keeps restarting (expired cursor or changing
  rules) now stops after two restarts per job and retries later, staying not-ready instead of looping. Build 28 (iPhone/iPad):
  **Enable Notifications** in Settings registers this device for visible APNs alerts (explicit permission prompt, push entitlement,
  lease and revocation, tap opens the checked item). It needs a Tower with an APNs provider key; until then Settings says
  "Waiting for Tower". The Mac has no push entitlement yet.

## Text attachments, browser favourites and bounded Mac threads (iPhone/iPad build 24, Mac build 14)

- **Long pastes become text attachments.** A paste over 2,500 Unicode code points, or one that would take the inline
  text over 10,000, is staged as a complete UTF-8 `.txt` file; Undo removes it. Staged and sent text cards open in a
  bounded editor (rename, edit, Save, Cancel); a sent edit saves a new Files version and keeps the signed message
  unchanged. See [Automatic text attachments](docs/mac.md#automatic-text-attachments).
- **Browser favourites.** The browser start page shows saved favourites over the start background. Add or remove the
  current page from the page menu, edit name and icon, add by address (https only), arrange the order; favourites are
  kept on this device.
- **Composer:** Hide keyboard now sits beside Attach photos instead of replacing it, so photos can be attached mid-sentence.
- **Mac threads** render a bounded 50-message page of the loaded 500, with Earlier/Newer replies, a remembered reading
  position for the app session, and native message menus built when opened. This addresses the post-save freeze seen
  on earlier Mac builds; it is validated with the sample-data regression harness, not yet on a live account.
- Known limit: on Mac the text editor's disabled Save button draws as a blank white control (enabled Save and Cancel
  are readable). These are locally built review builds; the Mac app is signed with Developer ID and not notarized.

## Connection recovery (iPhone/iPad build 22, Mac build 12; review builds)

Settings shows connection status; transient read failures retry a bounded number of times with recovery triggers; and
**Settings > Diagnostics > Export diagnostics** shares a redacted local text log of recent connection attempts (UTC time,
request kind, duration, error code; no keys, messages, names or record ids; nothing is sent unless you share it). The
original transport failure cause is unknown (backend contention is a hypothesis). These are review builds built locally
and not installed or published; behaviour on a live Tower is not yet confirmed.

## Mac new-thread fix (Mac build 11)

Deck’s **+** now displays the New thread composer instead of leaving the window with all content disabled and no
visible modal. Cancel, outside click and closing a submitted thread restore the underlying app. The Mac regression
harness exercises the real app window with isolated sample data; see [Mac validation](docs/mac.md#new-thread-interaction-regression).
The iPhone was on build 21 at that point.

## Interface parity fixes (iPhone build 21, Mac build 10)

- Chat tables keep a measured width per column, so wrapped cell text no longer overlaps between rows.
- Uploaded images and files leave the text field and appear as removable thumbnails above it (images open full size).
  Their Markdown stays after the typed text and is sent with the message exactly as before.
- Picked people and agents show as pills above the field and as highlighted `@Name` text. Up/Down move through the
  `@` list, Return or Tab picks, Esc closes it, and Backspace inside a picked name removes it whole. The visible name and
  the structured `mentions` entry are still derived from one value.
- Every message has a visible ⋮ menu (React, Copy message, FD Ref, Edit and Delete for your own messages) and a dot:
  green when Tower holds the message, amber while an edit or delete waits to send, red when Tower refused it.
- Desktop thread and New thread modals: click outside to close, a light dim over the screen behind, and an expand /
  restore button. New thread fills the window on Mac like the thread view.
- Deck: inbox rows carry a quiet colour per type (chats blue, tasks amber, documents green); desktop panels are open
  surfaces as on the web; iPhone **Apps** are cards with logos and descriptions.
- The message menu also has **Get it done** (a ready task from the conversation, with source link, output type, assignee and
  excerpt, as the web builds it; a Doc output does not create the document shell), **Branch from here** (Tower's thread
  branch route, then opens the new thread) and **Autopilot Link** (messages that came from an Autopilot session, opened at the
  workspace's Autopilot address).
- Desktop thread messages have more room and a faint line between them.
- Task comments: right-hand panel on desktop, Task / Comments tabs on iPhone, newest comment first.

## Mac layout stability (build 7)

Mac sidebar hiding keeps the split-view columns alive so Canvas and its live naplets retain their view state while
resizing. Long message drafts use cached text measurement limited to the composer's six visible lines, including
large pasted crash reports. The iPhone/iPad composer is unchanged. See [Mac validation](docs/mac.md#layout-regression-checks).

## What this build does

iPhone/iPad version 0.1.0 (31); Mac version 0.1.0 (22). You import your own `nsec` (sealed with a PIN plus a device-only Keychain secret),
enter your Tower's HTTPS origin, and the app reads the public nStack descriptor. It then lists your
workspaces, scopes (in your personal scope order, collapsible) and channels, and stores them locally.

Chat is native:

- Channel conversations and threads are read from the phone's database, and they catch up from Tower
  when you open them.
- Drafts are kept per channel and per thread, including across relaunch.
- Mentions are picked from the workspace directory.
- Messages are signed and sent through a durable outbox. That outbox survives locking, going offline
  and relaunching, retries on its own, and shows unsent, retrying and rejected messages with Retry,
  Edit and Discard.

Tasks, documents, files and inbox are native too (0.1.0 build 3):

- **Inbox** shows mentions, assignments and unread conversations from Tower's view states. Opening an item marks it read; Mark all read and task Done are available.
- **Tasks** as a list or board: create, change state, priority and assignee, edit, comment.
- **Docs** render natively from the stored ProseMirror model on a white page with a faint lavender surround. On iPhone and iPad the document opens directly into its formatted editor; on Mac, **Edit** turns that page into the editor: select, format from the toolbar (text style, bold, italic, strike, code, link, lists, tasks, quote, code block, divider, undo) and type in the formatted text; Markdown documents edit the same way and are saved as Markdown. Untouched content, unknown nodes, attributes, marks and images are written back exactly as stored. It holds Tower's edit lease, keeps a draft on the device, and never overwrites a newer version (Tower keeps a recovery copy instead). On iPhone/iPad, highlight a passage and choose **Comment on selected text**; the comment keeps its quote and reopens that passage after reload.
- **Files**: folders, checksum-verified download, QuickLook and Share, upload from Photos or Files.
- **Search** covers what is stored on the phone.
- **Chat** messages can be reacted to, edited (signed revision) and deleted; photos are attached without location or camera metadata.
- Every change goes through a durable queue that survives offline periods, locking and relaunch, and shows sending, retrying, failed and conflict states.

Live updates and background refresh (0.1.0 build 4):

- While the app is open, changes arrive live over Tower's event stream and are applied from a stored cursor, so
  nothing is missed across reconnects. Deletions and lost access remove local copies.
- In the background, iOS may grant short refresh windows; the app then runs the same sync jobs and stops when iOS says
  so. If the app was only suspended and is unlocked, waiting messages are sent too. After iOS has ended the app,
  nothing can be signed without your PIN unless you turn on **Refresh while locked** in Settings. That keeps a copy of
  your signing key in a device-only Keychain item, used under an app-enforced rule that only allows fetching updates from
  your Tower for your workspaces. Lock now removes it.
- Large uploads and downloads to the object store continue in a background transfer session.

Unlocking (build 5): when the identity is locked the app shows a full-screen unlock. After you enter your PIN it stays
unlocked on this iPhone, including across relaunch, until you choose Lock now, remove the identity or disconnect. The key
for this is kept in a device-only Keychain item that iOS opens only while the iPhone is unlocked.

Navigation and rendering (build 6): a sidebar, opened from the menu button in every mode, holds Home, Unread &
Active, your scopes (collapsible, in your order) with their channels, and the workspace switcher. The scope or channel
you choose is the shared context: Chat opens that channel (or lists the scope's channels), and Tasks, Docs and Files
show and create records there. It is remembered per workspace. Inbox and Search cover the whole workspace, show where
each result lives, and opening one moves the context there. Channels have Messages and Threads panes. Messages and
documents render Markdown natively (headings, lists, tasks, quotes, code, tables, links, mentions) with workspace
images loaded through the signed storage route.

Keeping your account (build 6): an update never asks you to import again. If the app is started while the iPhone is
locked, iOS keeps the identity file sealed; the app now says so and opens it once the iPhone is unlocked, instead of
showing "no identity". Imports are refused while an identity exists or for a key other than the connected one.

Workspace surfaces and pins (build 7): the sidebar has two new sections.

- **Pinned** lists your personal pins in the same order as on the web. Pin or unpin from a task, document, conversation
  or channel (the pin button in its toolbar). Pins are private to your identity and synced through Tower's record-sync
  feed.
- **Workspace** opens Canvas, Context, Agents and Toolbox over the tabs, with the same sidebar and Scope | Channel
  context. Anything you open from them goes back to where you were.
  - **Context** shows the chosen scope's Context Tree as an outline; a component lists its linked tasks, documents and
    files, which open natively. Links you cannot read show as "Not available to you".
  - **Canvas** shows each item at its saved position and size over the drawing. Pan and zoom are yours only and are
    never saved to the board. Items open natively (documents, conversations, tasks, other canvases); Excalidraw boards
    are drawn natively, and what cannot be drawn is listed. Locked items show only their frame.
  - **Agents** lists the workspace's agents and what they are doing in the current context, from Tower's records.
  - **Toolbox** lists your WApps (also under Deck › Hello and Links › Apps); each opens as an in-app browser tab, where
    it can ask to use your Nostr key, and **Ambulando** returns to where you launched it. HTML artefacts stay in a
    labelled, sandboxed web view with no signing.

Editing boards and the Context Tree, reordering pins, the pipeline viewer and Autopilot session control stay in the web
app. See the parity matrix for every gap. (Build 9 moved Pinned and the Workspace screens out of the sidebar; see below.)

Sidebar loading fix (build 8): builds 6 and 7 started reading scopes and channels only for a workspace chosen in the
switcher. Most people never choose one, so the sidebar stayed on "Loading navigation…" and the Chat channel list kept
spinning, although the data had been fetched. The app now shows the chosen workspace while Tower lists it, otherwise the
first listed one (without storing that as a choice), and starts its sidebar at launch and whenever the workspace list
arrives or changes. If Tower answers with no workspaces, nothing from a removed one stays on screen. The sidebar and the
Chat channel list now always say why they are empty: loading, a failed refresh with the error and **Retry**, locked, or
no scopes shared; when a refresh fails over saved scopes they stay visible with a "couldn't refresh" note. The launch
restores the open channel exactly once before it starts watching the workspace list, and no restore overwrites a channel
or thread the user opened after it began, so a later refresh never moves the screen or touches the composer.

Navigation like the web app (build 9): Canvas used to cover the five tabs with no way back to Chat. The app now follows
the web app on a phone:

- A **section bar** at the bottom on every screen, in the web's order: Deck, Chat, Tasks, Docs, Files, Agents and Context
  (optional, in Settings › Sections), Toolbox. Each section remembers where you were; tapping the current one goes back
  to its first screen. While you type, the keyboard covers the bar; the composer's Hide keyboard button (in place of the photo button) or dragging the conversation down puts it away.
- **Deck** is a set of cards you swipe between, with dots: Hello and Links, Inbox, Pinned items, Canvas, Feed, Recent.
  Deck's Inbox is the web's activity feed for the chosen scope or channel (conversations, open tasks, documents and
  files, newest first, unread marked), with type filters, search, Pin, Mark read, Mark done and Load older activity.
  Anything opened from Deck has Back to the same card. Canvas boards open from the Canvas card and keep their position.
  Feeds are not in the iPhone app yet; the Feed card says so.
- Choosing a scope or channel in the sidebar opens Deck for it, as on the web, unless you lock the current Chat, Tasks,
  Docs or Files view with the lock in the context bar.
- **Scope and channel management** from the sidebar, through the same Tower routes as the web: create a channel (+ on a
  scope), Channel settings (⋯: rename, context prompt, position, archive), and Manage scopes (your own scope order, and
  rename, describe, create or archive scopes you manage). Tower decides every change; a refusal says why. Channel and
  scope access, initial permissions and scope templates are still set in the web app, and the create screens say so.

Theme, names and avatars, chat separators (build 10):

- **Colours like the web app.** Pages, the chat list, the sidebar, the composer and the section bar are white (the web's
  card colour), and selected things are dark purple: a chosen channel or scope in the sidebar is bold purple on a light
  fill, and the Messages/Threads switch is solid purple. Dark mode keeps the navy and lavender palette.
- **Names and avatars.** Chat authors, the thread list, the profile button (top right) and Settings show a name and an
  avatar for each person. As on the web, the person's public Nostr profile names them first (build 12; build 10 put the
  workspace name first); otherwise the name set in the workspace, and someone with neither shows a short npub. Avatars come from the public profile (or, for an agent, from
  Tower); without a usable picture the initials are shown. Everything is saved on the iPhone and shown at once,
  offline too, and refreshed in the background (profiles daily, pictures when they change). Settings › Profile shows
  where your name comes from and your public profile name. Settings › Nostr profiles can turn the lookups off (saved
  names and pictures stay) or refresh everyone now.
- **Chat separators.** In a channel each conversation is a card, ending with its reply count when it has replies. A
  thread shows its first message, then a "N replies" rule, then the replies. A date label (Today, Yesterday, the
  weekday or the date) starts each day.
- A Deck card that was out of sight while records were removed (access lost, archived, deleted) no longer shows them
  again for a moment when you come back to it.

Paste images and files into chat (build 11):

- In a channel's or a thread's message box, choose **Paste** (or ⌘V) with an image or file on the clipboard. An
  "Uploading…" placeholder goes in at the cursor and the item uploads to workspace storage. When it finishes, the
  placeholder becomes the same storage image (`![name](storage://…)`) or file link (`[name](storage://…)`) the web app
  inserts. Images are privacy-stripped to PNG first, as picked photos are.
- Above the box each upload shows Preparing, Waiting, Uploading or why it failed (offline, locked, Tower's answer), with
  Retry and Remove. Send stays off while a placeholder is in the text; nothing is sent on its own.
- The result only ever goes to the conversation you pasted in: if you have moved on, it goes into that conversation's
  saved draft. After a relaunch an unfinished upload can be retried.
- Pasting text works as before. The app never looks at the clipboard except when you choose Paste. Up to 4 items per
  paste, 100 MB each.

Names and the in-app browser (build 12):

- **Names like the web app.** People are named from their public Nostr profile first, then the workspace name, then a
  short npub, everywhere: chat, the @-mention list (now with pictures), task assignees, documents and the sidebar.
  Pictures hosted on Blossom servers (such as Primal's), which always redirect to a CDN, now load, and pictures up to
  5 MB (was 2 MB) are shown.
- **Browser.** Web links in Ambulando open full-screen as tabs, and the globe button at the top of every screen opens
  the browser or a new tab (it shows how many are open). **Ambulando** at the top left goes back to exactly where you
  were, draft included; tabs keep their pages and back/forward history while the app runs. Pages are HTTPS only;
  links for mail, phone, messages, FaceTime, Lightning and Nostr apps ask before leaving.
- **Nostr signing in the browser** (`window.nostr`, NIP-07). A site asks before it can see your public key (you can
  remember or forget that per site). Every signature shows a sheet naming the site and what will be signed; only
  sign-in requests (NIP-42, NIP-98) can be allowed for a site until you lock. Locking cancels and refuses all
  requests. Your key never enters the page. Encryption (NIP-04/44) is not offered.

Web apps as browser tabs (build 13):

- **WApps and artifact links open in the browser.** Deck › Hello and Links › Apps, the Toolbox and Context Tree
  artifact links now open as full-screen browser tabs, with the same HTTPS checks, so a WApp can ask to use your Nostr
  key through the same approval sheets. **Ambulando** returns to the Deck card or Toolbox you launched from, and
  launching the same app again shows the tab it opened before. HTML artefacts are unchanged: a labelled, sandboxed
  view with no signing.

One bottom browser bar (build 15):

- **All browser controls are in one compact bar at the bottom**, with no toolbar above the page: **Ambulando** (back to
  exactly where you were), back, forward, the site address with a lock, the tab count and a ••• menu. Reload/Stop,
  Share, Open in Safari, New tab, Close tab, Forget Nostr permission and Clear browsing data are in the menu. Editing
  the address gives the field the whole bar, with Cancel, above the keyboard. The same browser is used on iPhone, iPad
  and Mac.

Live naplets, the focused thread view and Mac navigation (iPhone/iPad build 17, Mac build 5):

- **Naplets are live windows.** A selected naplet takes touches: conversations with a reply composer, documents with
  Comments and Edit, HTML artefacts inline in the web app's sandbox, and task trees with the real task graph (add a sub
  task or next task, open a node). Boards edit in the web app's Excalidraw editor, can be renamed from their window,
  and an unsaved board draft survives the app being killed.
- **Focused thread view.** Conversations open over the current screen, like the web's thread modal (a centred card on
  iPad and Mac, full height on iPhone), from chat, Deck, Search, pins, Inbox and canvases. Close returns to the same
  place; reopening a thread keeps its reading position for the app session.
- **Settings › About** shows Version, Build and Platform read from the installed app.
- **Mac build 5 includes Mac build 4** (clickable section bar, sized Tabs sheet, stacked launchers with logos, app text
  size). See [docs/mac.md](docs/mac.md).
- Not checked against a live Tower yet: naplet interaction, task-tree writes and board rename were tested on sample
  data in the simulator. Push notifications are still not turned on.

Canvas editing and the Mac revision (iPhone/iPad build 16, Mac build 3):

- **Create and edit canvases.** "+" on Deck's Canvas card makes a new board. On canvases you can manage, the pencil
  button lets you rename the board, add documents, tasks, conversations, HTML or board files and other canvases, drag
  items to move them, drag a corner to resize and remove items (with a confirmation). If someone else changed the board
  first, nothing is saved; the board refreshes and says so. Drawing tools and Excalidraw editing are not included yet.
  Same screens on iPhone, iPad and Mac.
- **Mac (build 3 includes everything from Mac build 2):** document comments anchored to selected text, white document
  paper with a right-hand comment column, image and file paste into content fields, a persistent top section bar,
  signed-browser links everywhere and a spatial Deck with Apps and My Agents. See [docs/mac.md](docs/mac.md).
- Push notifications are **not** turned on: build 16 contains only the app-side groundwork (payload, tap route and
  signed registration, with no Apple push entitlement and no Tower sender).

Security notes:

- Identity import is explicit. The app never searches for, reads or exports keys from other apps or
  the browser.
- Its Keychain service is `studio.otherstuff.ambulando.native.identity-vault.v1`.
- Only HTTPS origins are accepted, and redirects are refused.
- Public profiles are read, never written, from the web app's three public relays (relay.primal.net, nos.lol,
  purplepag.es) for the people your workspace shows, and each is checked against its author's signature. Pictures are
  fetched from the HTTPS address in the profile without any login, cookie or Tower data, refusing local addresses,
  large files (over 5 MB) and non-images. Up to three redirects are followed, each to an address that passes the same
  check (Blossom servers redirect every picture to their CDN). The relays and picture hosts can see your network address, as with the web
  app. Settings › Nostr profiles turns both off.
- `.fips` endpoints are refused rather than replaced with HTTPS.
- The in-app browser keeps website data in its own store, separate from the HTML-artefact view, and answers `window.nostr`
  only for the top frame of the HTTPS page shown in the tab (see architecture §4.9).
- Every request carries a fresh NIP-98 event over the exact URL and body bytes.
- Chat sends carry a kind 33358 signature over the exact (trimmed) message body. The request is frozen
  once signed and reused for every retry under the same `client_request_id`, so Tower replays instead
  of duplicating. Messages written while locked are signed only after you unlock.
- *Refresh while locked* (off by default) is the only way the app signs without the PIN, and only for GET requests to
  the pinned Tower and workspaces. It is not a cryptographically limited key; see architecture §6.
- Sample-data mode (`-AmbulandoUITestFixture`) exists only in Debug builds. It uses a throwaway key
  generated on the device and an in-process stand-in for Tower, and is labelled on every screen.

## Build and test

```sh
# Core tests on the Mac (no backend, public NIP-19 test key only)
swift test --package-path AmbulandoCore --scratch-path build/core

# Core tests on an iOS simulator
(cd AmbulandoCore && xcodebuild -skipPackagePluginValidation -scheme AmbulandoCore \
  -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath ../build/DerivedDataCore test)

# Isolated unattended sample apps (see docs/test-apps.md)
./scripts/test-app.py mac --reset
./scripts/test-app.py iphone --reset

# Normal app for the simulator (production authentication)
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando -configuration Debug \
  -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/DerivedData build

# Chat and WP4 UI automation on the simulator (local sample data, labelled in the app; not a live Tower)
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando \
  -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/dd test

# Mac app: build (Release, arm64 + x86_64), sign, install to /Applications and open; --package also writes a ZIP.
# Needs Xcode and bun (docs/mac.md). Its regression tests use stub tools and install nothing.
scripts/mac-install.sh
zsh scripts/tests/mac-install-test.sh

# Opt-in live checks (public descriptor + a signed discovery call made with the public test key)
AMBULANDO_LIVE_ORIGIN=https://<tower> swift test --package-path AmbulandoCore --scratch-path build/core --filter WhenConfigured
```

`-skipPackagePluginValidation` is needed for command-line builds because the pinned
`swift-secp256k1` 0.23.2 package (also used by NoteToSelf) runs a build-tool plugin. Do not commit
signing teams, provisioning profiles, device identifiers or build output. Keep run evidence in the
ignored `tmp/` directory or on the Flight Deck task.

The brand artwork in `Ambulando/Assets.xcassets` is copied from `sol/public/ambulando`.
`passage-app.png` and `passage-512.png` are byte-identical copies. The app icon is a `sips`
proportional resample of `passage-master.png` (SHA-256 `8f3988cf…244b`) to 1024 px on its original
opaque white backing. The Mac icon sizes (`AppIcon-mac-*.png`) are that icon inside the standard macOS rounded tile,
rendered by `swiftc -o /tmp/mac-icon scripts/mac-icon.swift && /tmp/mac-icon <AppIcon-1024.png> <appiconset dir>`.
The artwork retains its private provenance.
