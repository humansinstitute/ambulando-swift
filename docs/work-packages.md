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
