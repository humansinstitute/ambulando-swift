# Work packages

The packages run in dependency order. Each one ends with a tested, committed
slice and a handoff that states its evidence level (source, simulator, device or
live) and its gaps. Flight Deck tasks with the same names track the work.

| WP | Title | Depends on | Acceptance |
| --- | --- | --- | --- |
| 1 | Feature/API/auth/theme inventory and architecture | — | `docs/architecture.md`, `docs/parity-matrix.md`, this plan, Flight Deck tasks |
| 2 | Buildable SwiftUI app, persisted storage, secure auth, nStack connection | 1 | App builds and launches in the iOS simulator; SQLite store with migrations and row-version upsert; identity vault + NIP-98 + kind 33358 tested; nStack descriptor + workspace/scope/channel read path persisted and rendered from the store; sync-storm responsiveness test |
| 3 | Workspace/scope/channel navigation, chat and outbox | 2 | Real channel/thread history persisted and incrementally synced; composer with durable drafts; signed send through outbox with idempotent retry; scroll and draft stable across relaunch |
| 4 | Tasks, documents, files, inbox and other native surfaces | 3 | Each parity-matrix row for WP4 is delivered or explicitly re-scoped; read and write through existing routes; offline reads |
| 5 | Background sync, resume, retry, conflict handling, performance instrumentation | 3 (4 for its surfaces) | BGAppRefreshTask + expiration cancellation; foreground SSE with cursor resume; conflict policy; measured hitch/keystroke/launch budgets under a sync storm |
| 6 | Simulator/device validation and packaging | 5 | Exact build number, simulator test run, signed device build if signing is available (reported separately), install/launch evidence; no App Store submission |

## Build and test commands

```sh
# Core logic (macOS host, no backend, synthetic identities)
swift test --package-path AmbulandoCore

# Core logic on the iOS simulator
xcodebuild test -scheme AmbulandoCore -destination 'platform=iOS Simulator,name=<sim>' \
  -derivedDataPath build/DerivedData -packagePath AmbulandoCore   # or from AmbulandoCore/

# App for the simulator
xcodebuild -project Ambulando.xcodeproj -scheme Ambulando -configuration Debug \
  -destination 'platform=iOS Simulator,name=<sim>' -derivedDataPath build/DerivedData build
```

Opt-in live read (public descriptor only; no identity used):

```sh
AMBULANDO_LIVE_ORIGIN=https://<your-tower> swift test --package-path AmbulandoCore --filter LiveDescriptor
```
