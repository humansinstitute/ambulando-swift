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

Version 0.1.0 (7). You import your own `nsec` (sealed with a PIN plus a device-only Keychain secret),
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
app. See the parity matrix for every gap.

Security notes:

- Identity import is explicit. The app never searches for, reads or exports keys from other apps or
  the browser.
- Its Keychain service is `studio.otherstuff.ambulando.native.identity-vault.v1`.
- Only HTTPS origins are accepted, and redirects are refused.
- `.fips` endpoints are refused rather than replaced with HTTPS.
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
