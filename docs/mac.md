# Ambulando for Mac (native)

A macOS app target, `AmbulandoMac`, in the same Xcode project as the iPhone app. It is not the iPhone app running on a
Mac: it is built against the macOS SDK with its own entry point, window, sidebar, menus and text input. Everything below
the screens is shared:

- **AmbulandoCore** (unchanged): identity vault and signing, Tower HTTPS + NIP-98 transport, SQLite store, sync engine,
  live event stream, chat outbox and write queue, uploads and downloads.
- **`Ambulando/` views and model**: the Mac target compiles the same `AppModel` and section views (Chat, Deck, Tasks,
  Docs, Files, Agents, Context, Toolbox, Settings, browser). `Ambulando/App/Platform.swift` holds the few UIKit/AppKit
  differences under shared names; on the iPhone they resolve to exactly what was there before.
- **`AmbulandoMac/`**: Mac-only files: `MacApp.swift` (app, windows, delegate), `MacWorkspaceShell.swift` (sidebar
  window) and `AmbulandoCommands.swift` (menus and shortcuts). `App/AmbulandoApp.swift` and `App/AppDelegate.swift` are
  iPhone-only (excluded from the Mac target in the project file).

| | |
| --- | --- |
| Bundle identifier | `studio.otherstuff.ambulando.mac` (Debug builds: `studio.otherstuff.ambulando.mac.debug`) |
| Version | 0.1.0 (2) |
| Minimum macOS | 15.0 |
| CPU | Universal: Apple Silicon (arm64) and Intel (x86_64). Only Apple Silicon has been run. |
| Sandbox | App Sandbox, outgoing network, user-selected files (read/write); hardened runtime |
| Data | `~/Library/Containers/studio.otherstuff.ambulando.mac/` (kept when the app is replaced or updated) |
| Keychain | Login keychain, services `studio.otherstuff.ambulando.mac.identity-vault.v1`, `….session.v1` |

## Install on another Mac (for example a MacBook)

### Option A: the packaged app (ZIP)

`scripts/mac-install.sh --package` writes `dist/Ambulando-mac-<version>-<build>.zip` and a `.sha256` file next to it.

1. Copy the ZIP to the Mac (AirDrop or Files). Check it: `shasum -a 256 Ambulando-mac-0.1.0-2.zip` must match the
   `.sha256` file.
2. Double-click the ZIP and drag **Ambulando** into **Applications**.
3. The app is signed with a Developer ID certificate but **not notarized**. Gatekeeper assessment rejects this release
   as **Unnotarized Developer ID**, so a downloaded copy may be blocked. Use the source-build route below if macOS
   blocks it, or wait for a notarized package. These instructions do not change system security settings; an authorized
   Apple notary profile was not available for this delivery.
4. Once launched, import your `nsec`, choose a PIN and connect to your Tower, as on the iPhone. Each device keeps its own encrypted
   copy; nothing is copied from the iPhone.

To update, quit Ambulando first, then replace the app in Applications with the new one. Your identity, connection, saved data, drafts and
unsent messages stay (they live in the app's container and Keychain, not in the app).

### Option B: build from source

Requirements: macOS 15 or later, Xcode 26 (built with 26.3) selected with `xcode-select`, and network access the
first time (Swift Package Manager fetches `swift-secp256k1` 0.23.2 from GitHub).

Install Xcode and complete its first-launch setup. If it is installed at `/Applications/Xcode.app`, select it with:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Clone the repository, then build, sign, install and open the Mac app:

```sh
git clone https://github.com/humansinstitute/ambulando-swift.git
cd ambulando-swift
zsh scripts/mac-install.sh
```

Alternatively, use the committed source ZIP supplied with the release. It includes the project, core package and
these scripts; dependencies download on the receiving Mac. After unzipping `ambulando-native-source-<commit>.zip`:

```sh
cd ambulando-native-ip
zsh scripts/mac-install.sh
```

Both routes build Release for arm64 and x86_64. From either source directory, optional installer commands are:

```sh
zsh scripts/mac-install.sh --no-open  # build and install without opening
zsh scripts/mac-install.sh --package  # build, install, open, and write the ZIP and its SHA-256
```

The script installs to `/Applications` (or `~/Applications` if that is not writable), asks a running Ambulando to quit
first and stops if it does not, and only replaces the installed app once a complete, verified copy exists. A build made
on the same Mac has no quarantine flag, so Gatekeeper does not ask.

Signing: `AMBULANDO_SIGN_IDENTITY` if set, otherwise the first *Developer ID Application*, then *Apple Development*
identity in the keychain, otherwise ad-hoc. Only the identity's name is read. Use the same kind of identity for every
update on a Mac: macOS lets the signer that created a Keychain item read it silently. An ad-hoc build is a new signer
each time, so after each rebuild macOS asks once for the login password to let Ambulando read its Keychain item
(choose **Always Allow**); the installer preserves the app container; keep your normal backups.

`scripts/source-bundle.sh` writes `dist/ambulando-native-source-<commit>.zip` (the committed tree, via `git archive`).

## Desktop layout and commands

- One main window (minimum 900 × 600) with Home, Unread & Active, scopes, channels and the workspace switcher in a
  resizable sidebar. Deck, Chat, Tasks, Docs, Files, optional Agents/Context and Toolbox sit horizontally above main
  content and remain visible on record screens. The window toolbar has sync status, Search, Browser and Settings.
- The in-app browser (with `window.nostr`) is its own window; **Back to Ambulando** or closing it ends the browsing
  presentation, and websites can then no longer ask for signatures.
- Chat composer: Return sends, Shift-Return or Option-Return starts a new line. Paste or drop images and files into it,
  or use the paperclip (**Attach files**) or Photos button.
- Files: Download (checksum verified), Preview (Quick Look), Share, **Save As…** and **Open in Default App**.
- Settings, Search, document editing, unlock and management open as sheets over the window.

| Shortcut | Action |
| --- | --- |
| ⌘1 … ⌘8 | Sections, in top-bar order (Deck, Chat, Tasks, Docs, Files, [Agents], [Context], Toolbox) |
| ⌘[ | Back one screen in the current section |
| ⇧⌘H | Home (all workspace activity) |
| ⌘F | Search saved messages, tasks, documents and files |
| ⇧⌘B | Browser window · ⌘T new browser tab |
| ⌘R | Refresh now |
| ⇧⌘L | Lock now / Unlock… |
| ⌘, | Settings |
| ⌃⌘S | Show or hide the sidebar |

## Differences from the iPhone app

- **Background refresh:** macOS has no `BGAppRefreshTask`. While Ambulando runs (also with its window closed) changes
  arrive live and unsent work is retried; after quitting, nothing syncs until it is opened again. *Refresh while
  locked* (the iPhone's read-only background credential) is therefore not offered on the Mac.
- **One main window:** the model holds one navigation (section, context and open records), so a second main window
  would mirror the first. Independent windows per workspace or record would need per-window navigation state; not built.
- **Sections:** each section keeps its open record and path when you switch, but only the visible section is drawn, so
  a list's scroll position starts at the top again (on the iPhone it is kept). Drafts are kept either way.
- **Keychain and staying unlocked:** as on the iPhone, after you enter your PIN the app stays unlocked across relaunch
  by keeping the signing key in a Keychain item (`….session.v1`) until **Lock now**, removing the identity or
  disconnecting. On the iPhone that item is private to the app and readable only while the phone is unlocked. On a Mac
  it is in the login keychain, which is open whenever you are logged in; other apps cannot read it without macOS asking
  you first. Use **Lock now** (⇧⌘L) when you step away if that matters to you; the PIN is then needed again.
- **Not verified on the Mac:** an authenticated workspace session with a real member identity (live checks used the
  public NIP-19 test key, which has no workspaces), Intel Macs, and automated UI tests (there is no Mac UI test target;
  the Mac UI was checked with accessibility automation on sample data).
- Push notifications and FIPS transport are not part of either app.

## Sample data

Debug builds keep the iPhone's sample-data mode: launch with `-AmbulandoUITestFixture` (add `-AmbulandoFixtureReset`
to start over). It uses a throwaway key, an in-process stand-in for Tower and its own storage, is labelled on every
screen ("Sample data on this Mac"), and exists only in Debug builds, whose separate bundle identifier gives them their
own container and Keychain items. Release builds ignore the flag.

```sh
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme AmbulandoMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/ddmac build
open -n build/ddmac/Build/Products/Debug/Ambulando.app --args -AmbulandoUITestFixture
```

## Documents and content paste (Mac build 2)

Documents use white paper and dark text independently of the window theme. Comments and replies stay in a separate
right column with their own scroll area and a pinned composer. Select text in a native paragraph or heading and use
its **+** control to quote and comment. A thread's **Locate text** restores the highlight; deleted or ambiguous text
is labelled **Original selection unavailable**. Rich documents store the web's UTF-16 ProseMirror positions and quote
in comment metadata, with the source row version. Markdown selections use line/quote metadata instead of inventing
ProseMirror offsets. Existing rich structure, images, formatting and unknown JSON nodes remain intact.

Selection is within one native text block; dragging across separate paragraphs is not supported. Complex cells with
multiple paragraphs or inline objects can retain the standard rich renderer without a selection-comment control.
Unknown nodes remain visibly preserved rather than acquiring misleading anchors. A moved quote is located only when
it has a single unambiguous match.

Explicit image/file paste uses workspace storage in chat/thread composers, message editing, task comments, task
create/edit descriptions, document comments/replies, document creation/body/block editors, channel descriptions and
context prompts, and scope descriptions. Content fields use a bounded native text viewport, with visible upload state,
Remove and Retry. Paste inserts at the selection/caret; Send/Create/Save remains a separate action. Unresolved upload
placeholders cannot be committed. Document inserts become real rich image/file nodes. Names, titles, search/filter,
URLs, identity/PIN and other scalar settings retain ordinary text input. Text paste follows the native text path.

Ordinary rich-text links inherit the app's browser route. Toolbox, Deck and Context app launchers use the same signed
browser. Sandboxed HTML naplets have no signing bridge; a link leaves them only through the explicit browser-tab
handoff. Public-key/signature consent, origin/frame checks and lock/closed-window rejection remain in the shared
browser broker. **Open in Safari** remains an explicit browser-menu choice.


Mac Deck is a spatial dashboard: welcome/context and Apps/My Agents above an inbox with pins and canvases alongside.
At narrow widths the same panels stack vertically, with no horizontal swipe carousel. My Agents reads the existing
Tower actor-owned `/me/autopilot-agents` settings and opens configured secure URLs in the signed browser; it does not
add direct Autopilot session control. Its cached list is scoped to the connection and workspace, with an explicit Retry
when loading fails.
