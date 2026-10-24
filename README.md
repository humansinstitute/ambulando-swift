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

Version 0.1.0 (3). You import your own `nsec` (sealed with a PIN plus a device-only Keychain secret),
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

Personal pins remain a follow-up. See the parity matrix for gaps.

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
