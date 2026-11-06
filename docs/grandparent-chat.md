# Grandparent Chat (iPhone and iPad)

Grandparent Chat is a second, deliberately small app built from this repository: one installable app
(`Grandparent Chat`, bundle `studio.otherstuff.grandparentchat`, scheme `Grandparent Chat`) that always opens one
existing family conversation. It is the same canonical Tower conversation Ambulando shows: the same messages, replies
and photos are readable and writable from both. There is no second backend and no copied messages.

## What it shares and what it adds

- **Shared (not copied):** the whole `Ambulando/` source folder compiles into both targets, plus `AmbulandoCore`
  (identity vault, Tower transport, SQLite store, sync, outbox, drafts, profiles). The Grandparent target excludes only
  `AmbulandoApp.swift`, `AppDelegate.swift` and Ambulando's asset catalog.
- **Product configuration:** `Ambulando/App/Product.swift` (name, background-refresh id, test bundle id) selected by the
  `GRANDPARENT_CHAT` compilation condition, `Config/GrandparentChat-Info.plist`, `Config/GrandparentChat.entitlements`
  and `GrandparentChat/Assets.xcassets` (icon rendered by `scripts/grandparent-icon.swift`).
- **Added:** `GrandparentChat/` (app entry, delegate, family model, setup, conversation, settings) and, in
  `AmbulandoCore/Sources/AmbulandoCore/Family/`, the binding, access evaluation, routing guard and send guard.
- **Not exposed:** tasks, documents, files, feeds, branches, agents, tools, the sidebar and every other Ambulando
  screen. Ambulando's own sign-in screens are reused with family wording.

## The binding

One `FamilyBinding` per signing identity (`app_state` key `family.binding.v1:<npub>` in the connection catalog) names
the NStack origin, account, space (workspace + app npub), channel and **existing** conversation (thread). It is chosen
in setup by explicit selection from the channel's own list, fetched from Tower at that moment. The app never creates
a conversation and never picks one for the person. A channel with no conversation says to start it once in Ambulando.

Choosing a different family chat only forgets the binding. Cached messages, drafts and unsent messages stay in the
workspace partition under the conversation's own key. Change is refused while unsent messages are waiting.

## Safety rules (all tested in `FamilyBindingTests.swift`)

- Access states: signed out, different account, different NStack, checking, space/channel/conversation unavailable,
  archived (read-only here), ready. A missing record is "unavailable" only once its listing is known; a moved or other
  thread is never substituted.
- Notification and link routes can only resolve to the bound conversation; every other destination is ignored.
  Foreground alerts are never presented on top of it.
- **Per-attempt send guard.** `OutboxGuardSlot` is shared by the outbox of every workspace runtime (and fails closed
  until installed). Before each row's attachments upload and again before its request is posted, the guard re-reads the
  binding from disk, requires an exact origin/signer/space/app/channel/conversation match, asks Tower for the live
  workspace listing and thread (archived or deleted blocks; unreachable holds the row queued), and re-reads the binding
  after that wait. A message queued for an old family chat is never sent to a new one.
- The bound runtime is selected by the whole boundary (origin, signer, workspace id, app npub), and other spaces of the
  account are switched off once a binding exists.
- Sign out only locks (key, binding and messages stay). Removing the key is under Settings › Advanced with a confirmation.

## Build and test

```bash
cd AmbulandoCore && swift test --filter "FamilyBindingTests|FamilySendGuardTests"
xcodebuild -project Ambulando.xcodeproj -scheme "Grandparent Chat Test" -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build          # sample-data simulator build
xcodebuild test -project Ambulando.xcodeproj -scheme "Grandparent Chat Test" -destination 'id=<throwaway simulator>' \
  -skipPackagePluginValidation -skipMacroValidation                                        # GrandparentChatUITests
xcodebuild -project Ambulando.xcodeproj -scheme "Grandparent Chat" -configuration Debug -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=<team> -skipPackagePluginValidation -skipMacroValidation build           # signed debug device build
```

The `Test` configuration is the sample-data build (`studio.otherstuff.grandparentchat.test`, simulator only, runs against
an in-process stand-in for Tower and labels every screen "Sample data"). UI tests use a throwaway simulator, never a
shared one, and never a personal phone.

## Known limits

- No push notifications yet: the app has no `aps-environment` entitlement and Tower registration is not wired for this
  bundle identifier. The routing guard is in place for when alerts are added.
- No distribution (TestFlight/App Store) signing: only the development wildcard profile exists. A new App ID and
  distribution profile are needed, and must not reuse Ambulando's release identity.
- Live interoperability with a real Tower and family channel is not verified here; it is exercised against the sample
  Tower and the core protocol tests that Ambulando's chat already uses.
