# Work packages

The packages run in dependency order. Each one ends with a tested, committed
slice and a handoff that states its evidence level (source, simulator, device or
live) and its gaps. Flight Deck tasks with the same names track the work.

| WP | Title | Depends on | Acceptance |
| --- | --- | --- | --- |
| 1 | Feature/API/auth/theme inventory and architecture | — | `docs/architecture.md`, `docs/parity-matrix.md`, this plan, Flight Deck tasks |
| 2 | Buildable SwiftUI app, persisted storage, secure auth, nStack connection | 1 | App builds and launches in the iOS simulator; SQLite store with migrations and row-version upsert; identity vault + NIP-98 + kind 33358 tested; nStack descriptor + workspace/scope/channel read path persisted and rendered from the store; sync-storm responsiveness test |
| 3 | Workspace/scope/channel navigation, chat and outbox | 2 | Real channel/thread history persisted and incrementally synced; composer with durable drafts; signed send through outbox with idempotent retry; scroll and draft stable across relaunch. **Delivered in 0.1.0 (2), source + simulator** (see parity matrix). Personal pins and chat image attachments are a scoped follow-up |
| 4 | Tasks, documents, files, inbox and other native surfaces | 3 | Each parity-matrix row for WP4 is delivered or explicitly re-scoped; read and write through existing routes; offline reads. **Delivered in 0.1.0 (3), source + simulator** (see parity matrix). Personal pins (follow-up bb1dbde7) and the listed per-row gaps stay open |
| 5 | Background sync, resume, retry, conflict handling, performance instrumentation | 3 (4 for its surfaces) | BGAppRefreshTask + expiration cancellation; foreground SSE with cursor resume; conflict policy; measured hitch/keystroke/launch budgets under a sync storm. **Delivered in 0.1.0 (4), source + simulator, first iPhone readings** (see parity matrix and architecture §5.2–§5.5). Open: the 50 ms typing max is not met on the simulator (attributed to test harness and keyboard presentation), scroll hitch ratio and real OS-granted background windows need the phone (WP6), and no live Tower stream has been exercised. Build 5 (task 9333df01): full-screen unlock and trusted-device session, background catch-up of all channels, source-less threads shown |
| 7 (build) | Canvas, Context Tree, agents, Toolbox and personal pins (task 6b035d34, pins task bb1dbde7) | 6 | Native surfaces over existing Tower routes with persisted, bounded, cancellable reads; ACL/error handling tested; simulator flows; upgrade retention 6 → 7; typing regression with budgets unchanged. **Delivered in 0.1.0 (7), source + simulator** (see parity matrix rows for exact gaps). Not yet installed on the phone; pipeline viewer needs a contract decision |
| 8 (build) | Sidebar navigation repair (task 0f470ce1) | 7 | Workspace → Scope → Channel loads with no stored workspace choice, a stale choice or an empty list; loading, error + Retry, locked and empty states instead of an unexplained empty sidebar; one context restore at launch and none over what the user opened; upgrade retention 6 → 8 and 7 → 8. **Delivered in 0.1.0 (8), source + simulator**; phone install recorded in the task |
| 9 (build) | Navigation like the web app, scope and channel management (task 0f470ce1) | 8 | Bottom section bar in the web's order; Deck as swipeable cards with the web's context-filtered Inbox, Pinned items, Canvas, Feed (labelled pending) and Recent; Canvas opened inside Deck with Back and Chat one tap away; sidebar choice opens Deck unless the view is locked (web); sections keep their screen, scroll, board position and drafts; create/rename/prompt/position/archive channels and scope order/rename/create/archive through existing Tower routes with permission-aware refusals and conflict handling; build 8 startup guards kept. Core + simulator UI tests, upgrade 8 → 9. **Pending native work:** channel and scope access grants, initial permission rows, scope templates, canvas create/rename/visibility, pin reorder, Feed client |
| 10 (build) | Theme surfaces and highlights, Nostr names and avatars, chat separators (task 0f470ce1) | 9 | Sol `styles.css` surfaces (`--card` pages, `--background` behind grouped forms) and highlights (muted + primary selected rows, solid primary tabs and avatar fallbacks) in light and dark; schema 5 public-profile cache per connection (kind 0 from sol's relay list, verified, newest wins, 24 h / 6 h freshness, pruned to referenced people) and avatar thumbnail cache (HTTPS, no credentials or redirects, size/pixel caps, ImageIO off-main, bounded, versioned); Tower names first; profile button and Settings › Profile/Nostr profiles; chat conversation cards, reply bar, thread replies rule and date labels; hidden Deck cards never re-show removed records. Core + simulator UI tests and screenshots (sample data), upgrade 9 → 10 (one run, no workspace choice). Fast human-test release: the full UI suite and the stale-choice upgrade were not rerun on the final source (ChatFlow 8/8 and Profiles 3/3 were); the 50 ms typing maximum is still not met. **Not live-verified:** relay reads against real profiles; phone install recorded in the task |
| 11 (build) | Paste images and files into chat (task 2d624a7d; release tracked in task 36422da6) | 10 | Explicit Paste in channel and thread composers uploads to workspace storage through the existing routes and inserts the web's storage Markdown at the caret. Text paste unchanged; progress, Retry and Remove; no send while a placeholder remains; no auto-send; results only in the captured target; nothing changed on Tower. Core tests (`ComposerUploadTests`, full core suite) and simulator UI tests (`PasteUploadUITests` plus the affected `ChatFlowUITests`). **Delivered in 0.1.0 (11), source + simulator**; fast human-test release from source `21c2758`: core 254 passed / 0 failed (2 live-only skips) and the affected UI tests 22/22, not rerun after the build-number bump; no full UI suite and no 10 → 11 upgrade run (no schema change). Phone install recorded in the task. **Not live-verified:** paste/upload against a real workspace (needs Pete); the 50 ms typing maximum is still not met. The in-app browser is a separate, later build |
| 12 (build) | Names like the web and avatars (task eef7f2b4), in-app browser with NIP-07 signing (task 1984dc90); release tracked in task 9c878214 | 11 | Public Nostr profile name first, then the usable Tower name, message label and short npub, everywhere including the @-mention picker (with avatars), pickers and sidebar. Avatars follow up to 3 re-checked redirects (Blossom → CDN), 8 s relay budget, download cap 5 MiB (was 2 MB; pixel, thumbnail, disk and concurrency bounds unchanged). Full-screen browser tabs over the app with Ambulando return, tab switcher, HTTPS-only policy and external-app hand-off; `window.nostr` bound to top frame, origin and document, per-origin public-key permission, a sheet for every signature (kinds 22242/27235 may be allowed until lock), lock cancels everything. Core 266 executed / 0 failed / 4 live-only skips on source `e714ad8`, then the focused `AvatarStoreTests` (10/0) and one live read of a 2.17 MB Blossom avatar after the cap change; simulator UI `ProfilesUITests` and `BrowserUITests` passed. No full UI suite and no 11 → 12 upgrade run (no schema change). **Delivered in 0.1.0 (12)**; phone install recorded in the task. **Not live-verified:** the browser against a real artefact or third-party site with a real identity (needs Pete), names on the live workspace. **Gaps:** NIP-04/44, bookmarks, tab restore after relaunch. The 50 ms typing maximum is still not met |
| 6 | Simulator/device validation and packaging | 5 | Exact build number, simulator test run, **signed install and launch on Pete's own iPhone with on-device verification (required acceptance)**, device evidence reported separately from simulator evidence; no App Store submission. A simulator build is not project completion |

## Build and test commands

```sh
# Core logic (macOS host, no backend, synthetic identities)
swift test --package-path AmbulandoCore

# Core logic on the iOS simulator
xcodebuild test -scheme AmbulandoCore -destination 'platform=iOS Simulator,name=<sim>' \
  -derivedDataPath build/DerivedData -packagePath AmbulandoCore   # or from AmbulandoCore/

# Signed device build (no account changes: local team profile only; pass the team on the command line, never commit it)
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/device DEVELOPMENT_TEAM=<team> build
xcrun devicectl device install app --device <device> build/device/Build/Products/Debug-iphoneos/Ambulando.app

# App and chat UI automation (sample data) for the simulator
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme Ambulando \
  -destination 'platform=iOS Simulator,name=<sim>' -derivedDataPath build/dd test

# App for the simulator
xcodebuild -project Ambulando.xcodeproj -scheme Ambulando -configuration Debug \
  -destination 'platform=iOS Simulator,name=<sim>' -derivedDataPath build/DerivedData build
```

Opt-in live read (public descriptor only; no identity used):

```sh
AMBULANDO_LIVE_ORIGIN=https://<your-tower> swift test --package-path AmbulandoCore --filter LiveDescriptor
```

## Upgrade retention check (simulator only, synthetic data)

Release gate for every build that changes storage, identity or startup. Never run against a real account or device.

1. Create and boot a fresh simulator. Check out the previous release (for build 6: `7919b00`) in an ignored worktree
   under `tmp/`, add an untracked UI test there that launches the app normally and imports the public NIP-19 test key
   (`TestKeys.nsec`, PIN 246810) through the import screen, and run it on that simulator.
2. With the app not running, write synthetic rows into its store (`xcrun simctl get_app_container <sim>
   studio.otherstuff.ambulando.native data`): a connection to `https://tower.example.invalid` for the test npub, one
   workspace, scope and channel, `selected.connection`/`selected.workspace:<c>`, a `chat-path:<c>:<w>` with the channel
   route, a channel draft and an `awaiting_signature` outbox row. Record the SHA-256 of `Identity/vault.json`.
3. From this checkout run `TEST_RUNNER_AMBULANDO_UPGRADE_CHECK=1 xcodebuild … test
   -only-testing:AmbulandoUITests/UpgradeRetentionUITests` on the same simulator (installs over the old build without
   deleting data), then compare the vault hash and remove the worktree.

Build 6 result: passed (twice, second run = further relaunch); vault hash unchanged; `vault.pub` written; installed
`CFBundleVersion` 6.

Build 7 result (previous release `b31005a`, build 6; fresh "Ambulando Upgrade 6to7" simulator): passed twice; vault SHA-256
identical before and after; store migrated from schema 3 to 4; draft kept; the unsent message kept (it moves to
`retrying` against the invalid origin); the new sidebar sections present; installed `CFBundleVersion` 7. The synthetic
rows now read "previous build" instead of naming a build. Helper files used: ignored `tmp/upgrade7/`.

From build 8 the check is run in the states real phones are in, not only with a stored workspace choice: seed once with
no `selected.workspace:<c>` row (a workspace is stored as a choice only when the switcher is used, so most phones have
none; this is what hid the build 6–7 sidebar failure) and once with a choice for a workspace that is not listed. Both
must restore the open channel, list the scopes in the sidebar and keep identity, connection, draft and outbox.

Build 8 result (fresh simulators, two upgrade runs each): 6 → 8 with no workspace choice (previous release `b31005a`)
and 7 → 8 with a choice Tower no longer lists (previous release `b4168ac`) both passed twice. Vault SHA-256 identical
before and after; store at schema 4 (migrated from 3 for build 6); connection, workspace, draft and the unsent message
kept (it moves to `retrying` against the invalid origin); the stale choice is left as stored, not replaced by the
default; installed `CFBundleVersion` 8. Helper files used: ignored `tmp/upgrade8/`.

Build 9 result (previous release `f56d5d6`, build 8; fresh iPhone 17 Pro simulators, two upgrade runs each): 8 → 9 with
no workspace choice and 8 → 9 with a choice Tower no longer lists both passed twice. Vault SHA-256 identical before and
after; store schema 4 (no migration); connection, workspace, context, draft and the unsent message kept (it moves to
`retrying` against the invalid origin); the stale choice is left as stored; the saved Chat section is restored in the new
section bar and Agents/Context stay visible for the upgraded install; installed `CFBundleVersion` 9. The validation
script now boots each simulator before seeding and before every run: a first attempt was void because xcodebuild had
shut the fresh simulator down after the import step, so nothing was seeded. Helper files used: ignored `tmp/upgrade9/`.

Build 10 result (previous release `5b7c0d4`, build 9; fresh iPhone 17 Pro simulator; fast release, one run with no workspace
choice only, the stale-choice case not run): identity, connection, workspace, scope, channel, context, draft and the
unsent message kept (it moves to `retrying`); vault SHA-256 and the cached file identical before and after; store
migrated from schema 4 to 5 with an empty `profiles` table; no workspace choice written; resumed unlocked with the open
channel, sidebar, Chat section, Tower connection and the profile header showing the npub; installed `CFBundleVersion` 10.
One assertion failed: "Agents and Context … stay visible as sections". That assertion checks the build 8 → 9 migration
(build 9 turns both sections on once, at its first launch, only if a connection is already stored). In this procedure
the previous build first launches during the key import, before the connection is seeded, so build 9 stored both as
off; build 10 kept the stored values (`sections.agents`/`sections.context` = 0) and does not change this code. Before
the next upgrade check, make that assertion follow the stored preference (or seed it) instead of expecting both
visible. Helper files used: ignored `tmp/upgrade10/`.
