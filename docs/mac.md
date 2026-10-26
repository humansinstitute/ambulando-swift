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
| Version | 0.1.0 (11) |
| Minimum macOS | 15.0 |
| CPU | Universal: Apple Silicon (arm64) and Intel (x86_64). Only Apple Silicon has been run. |
| Sandbox | App Sandbox, outgoing network, user-selected files (read/write); hardened runtime |
| Data | `~/Library/Containers/studio.otherstuff.ambulando.mac/` (kept when the app is replaced or updated) |
| Keychain | Login keychain, services `studio.otherstuff.ambulando.mac.identity-vault.v1`, `….session.v1` |

## Install on another Mac (for example a MacBook)

### Option A: the packaged app (ZIP)

`scripts/mac-install.sh --package` writes `dist/Ambulando-mac-<version>-<build>.zip` and a `.sha256` file next to it.

1. Copy the ZIP to the Mac (AirDrop or Files). Check it: `shasum -a 256 Ambulando-mac-0.1.0-11.zip` must match the
   `.sha256` file.
2. Double-click the ZIP and drag **Ambulando** into **Applications**.
3. The app is signed with a Developer ID certificate but **not notarized**. Gatekeeper assessment rejects this release
   as **Unnotarized Developer ID**, so a downloaded copy may be blocked. Use the source-build route below if macOS
   blocks it, or wait for a notarized package. These instructions do not change system security settings; an authorized
   Apple notary profile was not available for this delivery.
4. Once launched, import your `nsec`, choose a PIN and connect to your Tower, as on the iPhone. Each device keeps its own encrypted
   copy; nothing is copied from the iPhone.

For delivery systems with a small request limit, the same signed app may be supplied as
`Ambulando-mac-0.1.0-11.tar.xz`. Extract it in Terminal from the download folder:

```sh
tar -xJf Ambulando-mac-0.1.0-11.tar.xz
codesign --verify --strict --deep Ambulando.app
```

Then drag the extracted **Ambulando** into **Applications**, as above. The archive format does not change the app’s
signature or notarization status. To create this smaller archive after the normal signed build:

```sh
zsh scripts/mac-install.sh --no-install --package
tar -cf - -C build/mac-release/Build/Products/Release Ambulando.app | xz -9e > dist/Ambulando-mac-0.1.0-11.tar.xz
```

Creating the archive requires `xz`; extracting it uses the Mac’s built-in `tar`.

To update, quit Ambulando first, then replace the app in Applications with the new one. Your identity, connection, saved data, drafts and
unsent messages stay (they live in the app's container and Keychain, not in the app).

### Option B: build from source

Requirements: macOS 15 or later, Xcode 26 (built with 26.3) selected with `xcode-select`, [bun](https://bun.sh) for
the embedded board editor (built with bun 1.4.4), and network access the first time (Swift Package Manager fetches
`swift-secp256k1` 0.23.2 from GitHub; bun fetches the board editor's locked dependencies from the npm registry).

Install Xcode and complete its first-launch setup. If it is installed at `/Applications/Xcode.app`, select it with:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Install bun if `bun --version` does not print a version (then open a new Terminal window), or update an older one:

```sh
curl -fsSL https://bun.sh/install | bash   # install
bun upgrade                                # update an existing bun
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

The script prints a line for each step: Xcode and macOS versions, board editor (with the bun version), app build,
signing identity, the built version and build, the app it replaces, the installed version read back from
Applications, and which copy is running after it opens. A successful run ends with:

```text
==> Installed /Applications/Ambulando.app: Ambulando 0.1.0 (build 12)
==> Running: /Applications/Ambulando.app, Ambulando 0.1.0 (build 12)
    In Ambulando, Settings > About should show Version 0.1.0 and Build 12.
```

If any step fails, it prints why (xcodebuild's errors and failed commands, the end of the build log, codesign's
message) and a final `==> FAILED (exit N) while <step>` line that says whether anything in Applications changed.
If the output ends without a `FAILED` or `Running:` line, the script is out of date: run `git pull --ff-only` again.
To send the whole output and both logs for diagnosis:

```sh
zsh scripts/mac-install.sh 2>&1 | tee ~/Desktop/ambulando-install.txt; echo "exit status: ${pipestatus[1]}"
tail -n 80 build/mac-release.log build/board-editor.log
```

Other copies of Ambulando on the Mac (for example an older one in `~/Applications`, or a Dock icon pointing at it) open
the version they contain. The script lists them with their versions and leaves them in place; remove them yourself
once the new one works. Settings > About shows the running app's Version and Build.

Both routes build Release for arm64 and x86_64. From either source directory, optional installer commands are:

```sh
zsh scripts/mac-install.sh --no-open  # build and install without opening
zsh scripts/mac-install.sh --package  # build, install, open, and write the ZIP and its SHA-256
```

The script installs to `/Applications` (or `~/Applications` if that is not writable, or `AMBULANDO_INSTALL_DIR`),
asks a running Ambulando to quit first (wherever it was opened from) and stops if it does not, refuses to install on a
macOS older than the app's minimum, and only replaces the installed app once a complete, verified copy exists. If an
earlier run was interrupted after setting the old app aside, the next run puts it back before updating. A build made
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
| ⌘+ · ⌘− · ⌘0 | View › Increase, Decrease and Actual Text Size (the app's text, kept across launches) |

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
  public NIP-19 test key, which has no workspaces), Intel Macs, and external pointer automation on the release app. The Debug new-thread harness below runs in-process AppKit interactions on sample data; there is no Mac XCTest UI target.
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

## Editing documents on the page

A document opens as a white page with dark ink on a faint lavender surround, in light and dark mode alike, with
comments in the right column. **Edit** (or **Continue editing** when a draft exists) turns the page itself into the
editor: the title becomes a field, a formatting bar appears above the page (text style and headings, bold, italic,
strikethrough, inline code, link, bulleted, numbered and task lists, quote, code block, divider, undo, redo; the usual
shortcuts such as ⌘B and ⌘I work), and **Cancel** and **Save** (⌘S) sit beside it. The lease state and unsaved changes
show under the title. Cancel with changes asks whether to keep the draft on this Mac or discard it. In a narrow window
the bar takes two rows and the less used tools move into a More menu. The page follows the app's text size.

The editor is the web app's own document editor (Tiptap with sol's schema), built into the app (`BoardEditor/`,
`document.html`) and shown in a web view with no signer, keys, network or website data; the app hands it the stored
document and its images and takes the edited document back. Rich documents keep every node, attribute and mark the
editor does not know (unknown nodes appear as a "kept unchanged" chip), and anything the user did not change is written
back as the stored JSON. Markdown documents are edited formatted and saved as Markdown; blocks the user did not change
keep their exact source. Pasted or dropped images and files go through the same paste pipeline as chat (metadata
stripped, uploaded with Retry and Remove; Save waits until they are done). Saving uses the edit lease and version
checks as before: someone else's newer save turns yours into a recovery copy and keeps your draft. Read mode keeps
the native renderer with text selection and the **+** comment control. Canvas documents open this screen too.

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

## Naplets, focused threads and About (Mac build 5)

Build 5 is Mac build 4 plus the shared iPhone/iPad build 17 changes: live naplets (conversation, document, HTML, task
tree), board rename and draft recovery, the focused thread card over the current window (Escape closes it), and
Settings › About with separate Version, Build and Platform rows from the installed app's Info.plist. It is signed with
Developer ID and **not notarized**.

## Navigation, launchers and text size (Mac build 4)

- The section bar is a plain row of buttons. A horizontal scroll view had swallowed real mouse clicks (accessibility
  presses still worked); when the labelled row does not fit, the same buttons show icons with the name as tooltip.
- The Tabs sheet has a real size on the Mac (it had collapsed to its toolbar): it lists, selects, opens and closes tabs.
- Deck Apps and My Agents are stacks like the web's: the first launcher with up to two card edges behind it; clicking
  the stack lists every launcher in a popover. Logos come from local bytes only: public HTTPS icons and favicons through
  the credential-free avatar cache (thumbnail PNGs on disk, shown offline), `storage://` icons through the signed file
  cache. Initials show until a logo loads and stay when none does.
- **Text size:** macOS SwiftUI ignores Dynamic Type sizes, so the app's text styles go through `Font.amb` and
  `TextScale` (0.85× to 2×, View menu and ⌘+ ⌘− ⌘0). It applies to every window and sheet, including list rows
  (`appRowTextSize`). System pop-up menus, list section headers and footers, and web pages keep their own size. The
  shortcuts act in the main window and its sheets; in the Browser window use the View menu.
  The iPhone and iPad keep Dynamic Type.
- Channel settings, Settings and New channel/scope use grouped, scrolling forms sized to fit the smallest window.


## Layout regression checks

Mac build 7 retains both `HSplitView` children when the sidebar is hidden. The sidebar becomes zero-width,
noninteractive and hidden from accessibility; showing it restores its resizable width range. This avoids rebuilding
the detail hosting hierarchy during a toggle. Canvas layout, selections and drafts remain in the existing views.

The Mac composer measures a detached prefix only until the six-line viewport is full, and caches up to eight width
results for the current text, font and line limit. It does not resize the live text container during measurement.
This keeps a long pasted report from being fully typeset for every speculative SwiftUI layout proposal.

Run the AppKit measurement regression check on a Mac:

```sh
swiftc -parse-as-library Ambulando/Views/MacComposerMeasurement.swift \
  scripts/tests/mac-composer-measurement.swift -o /tmp/mac-composer-check
/tmp/mac-composer-check
```

For automated UI checks, launch a separate Debug sample-data app and run:

```sh
swift scripts/tests/mac-sidebar-regression.swift <fixture-pid>
```

The script refuses apps without the sample-data banner. It checks repeated Canvas navigation toggles/resizes,
other sections, and long composer draft readback without sending. It uses accessibility actions, not physical
mouse/keyboard input, and leaves a sample draft in Chat.

For further UI validation, use an isolated Debug sample-data app (never reset an everyday app's identity or store):

1. Open Deck → Launch board. Repeatedly hide/show the sidebar and resize between 900 × 600 and 1440 × 900.
   Check the same board, selected naplet, viewport, editor draft and toolbar remain available.
2. Repeat with a conversation naplet selected and while its composer contains a long multiline draft.
3. In Chat, enter a large multiline report and a long unbroken line; resize and toggle navigation, then edit, select,
   delete and type again. Check the composer stays at most six lines and the draft remains intact without sending.
4. Repeat navigation toggles in Tasks, Docs, Files, Toolbox and Deck, including document comments/editing.
5. Check deactivate/reactivate and window close/reopen. Real sleep/wake and authenticated Tower checks must be
   reported separately from fixture or simulated lifecycle checks.

The reported build 5 exception did not include its reason string. Sidebar hierarchy changes are a plausible trigger,
not a proven explanation of that historical exception. The separate long-message hang report directly identified
full-draft composer measurement on the main thread.


## New-thread interaction regression

Mac build 11 fixes a presentation input trap: the app disabled its background when either a thread or New thread
was open, but chose the existing-thread overlay for both states. Since there was no existing thread, nothing appeared.
The presenter now chooses the existing-thread panel when a thread exists, otherwise the New thread panel when composing.
The background remains inactive only while a modal is shown.

The reusable, **Debug-only** in-process AppKit harness runs against the actual Mac app window. It requires both launch
flags below, uses a fresh fixture database and memory-only test credentials, and never connects to Tower or reads the
normal account. It exits nonzero on an assertion failure or after a 180-second timeout. The same visible-composer
assertion fails on the old presenter. Release builds contain no harness code.

```sh
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme AmbulandoMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/mac-thread-regression build
build/mac-thread-regression/Build/Products/Debug/Ambulando.app/Contents/MacOS/Ambulando \
  -AmbulandoUITestFixture -AmbulandoMacThreadRegression > build/mac-thread-regression.log 2>&1
```

Checks cover Deck +, native text entry, mention selection, Cancel, draft-preserving reopen, local mouse clicks through
the real window, narrow/wide resizing, modal expand/restore, macOS fullscreen when available, outside-click dismissal,
fixture-backed submission, closing the accepted thread, and underlying section navigation after dismissal. Each capture
is emitted as a `SNAPSHOT_BASE64 <name> <PNG base64>` line in the log; ordinary action and assertion lines remain readable.
`OS_FULLSCREEN entered=false` explicitly records an unavailable fullscreen check rather than treating it as verified.

These checks exercise AppKit hit testing and accessibility actions inside the process. They do not establish external
hardware mouse/keyboard delivery, a real-account Tower round trip, Intel execution, or notarization.

The post-save checks require the accepted message to render, then create twelve replies in the same fixture thread
and twelve other inbox conversations while resizing and expanding/restoring the open panel. The replies are fetched
through the normal sync transport and must reach both the local store and the rendered thread. The reply composer
must accept an unsent draft, the panel must close, and Chat navigation must respond. Four further create/send/close
cycles include multiline Markdown and tables. Each completed thread emits `POST_SAVE_PASS` with reply count and its
maximum measured response interval. A 100 ms main-actor heartbeat spans submission and rendering; a delay of two
seconds fails the run, and an independent watchdog bounds a main actor that never resumes. These are responsiveness
guards, not frame-rate measurements or proof that shorter hitches cannot occur.

To reduce an intermittent failure, add `-AmbulandoMacPostSaveOnly` to skip the earlier cancel/fullscreen/outside-click
sequence and run five create/send/close cycles. Add `-AmbulandoMacPostSaveStatic` to omit window resizing and modal
expand/restore, and/or `-AmbulandoMacPostSaveNoSync` to omit the added member replies/inbox conversations. Normal send,
thread/channel refresh and query paths still run in the latter control. `POST_SAVE_STEP` records the active options
and the last attempted sizing/sync step. All modes still require both fixture and Mac regression launch flags above.

Keep a post-save beachball separate from the build 11 presentation input trap. A short stackshot in AttributeGraph,
RootGeometry or `sizeThatFits` identifies sampled layout work, but does not by itself establish a deadlock, a callback
loop, or a specific expensive view. A passing fixture run cannot establish that a historical real-account hang is
fixed. Preserve failed-run logs as well as passes; report an earlier assertion failure separately if it prevents the
post-save checks from running. For a reproducible stall, retain the last action/heartbeat, capture a process sample
while stalled, and reduce the fixture to the smallest triggering content/update sequence before changing production
layout. Operational reports, logs and captures belong in ignored `tmp/docs/handoffs/`, not tracked product docs.
