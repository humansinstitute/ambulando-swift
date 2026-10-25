# Ambulando for iPhone (native)

A native SwiftUI client for Ambulando (Wingman Flight Deck) workspaces. It is a separate renderer, not
a WebView: screens draw from an on-device SQLite store, and one sync engine is the only owner of
network work against the existing Tower HTTPS + NIP-98 API. The web client lives in `../sol`.

- Architecture, inventory and budgets: [docs/architecture.md](docs/architecture.md)
- Feature parity with the web app (native / web / deferred / unsupported): [docs/parity-matrix.md](docs/parity-matrix.md)
- Work packages and commands: [docs/work-packages.md](docs/work-packages.md)

## Layout

| Path | Contents |
| --- | --- |
| `Ambulando.xcodeproj`, `Ambulando/` | App target `studio.otherstuff.ambulando.native`, iOS 18+, iPhone; SwiftUI views, theme, assets |
| `AmbulandoCore/` | UI-free Swift package: identity vault and signing, Tower transport, SQLite store, sync engine, probes |

## What this build does

Version 0.1.0 (10). You import your own `nsec` (sealed with a PIN plus a device-only Keychain secret),
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
- **Docs** render natively from the stored ProseMirror model. The editor changes only the text you touch and keeps formatting, block ids and unknown content. It holds Tower's edit lease, keeps a draft on the phone, and never overwrites a newer version (Tower keeps a recovery copy instead).
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
  - **Toolbox** lists your WApps; each opens in a labelled web view that stays on the WApp's own HTTPS origin.

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
  Pictures hosted on Blossom servers (such as Primal's), which always redirect to a CDN, now load.
- **Browser.** Web links in Ambulando open full-screen as tabs, and the globe button at the top of every screen opens
  the browser or a new tab (it shows how many are open). **Ambulando** at the top left goes back to exactly where you
  were, draft included; tabs keep their pages and back/forward history while the app runs. Pages are HTTPS only;
  links for mail, phone, messages, FaceTime, Lightning and Nostr apps ask before leaving.
- **Nostr signing in the browser** (`window.nostr`, NIP-07). A site asks before it can see your public key (you can
  remember or forget that per site). Every signature shows a sheet naming the site and what will be signed; only
  sign-in requests (NIP-42, NIP-98) can be allowed for a site until you lock. Locking cancels and refuses all
  requests. Your key never enters the page. Encryption (NIP-04/44) is not offered.

Security notes:

- Identity import is explicit. The app never searches for, reads or exports keys from other apps or
  the browser.
- Its Keychain service is `studio.otherstuff.ambulando.native.identity-vault.v1`.
- Only HTTPS origins are accepted, and redirects are refused.
- Public profiles are read, never written, from the web app's three public relays (relay.primal.net, nos.lol,
  purplepag.es) for the people your workspace shows, and each is checked against its author's signature. Pictures are
  fetched from the HTTPS address in the profile without any login, cookie or Tower data, refusing local addresses,
  large files (over 2 MB) and non-images. Up to three redirects are followed, each to an address that passes the same
  check (Blossom servers redirect every picture to their CDN). The relays and picture hosts can see your network address, as with the web
  app. Settings › Nostr profiles turns both off.
- `.fips` endpoints are refused rather than replaced with HTTPS.
- The in-app browser keeps website data in its own store, separate from Toolbox views, and answers `window.nostr`
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

# App for the simulator
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando -configuration Debug \
  -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/DerivedData build

# Chat and WP4 UI automation on the simulator (local sample data, labelled in the app; not a live Tower)
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando \
  -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/dd test

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
opaque white backing. The artwork retains its private provenance.
