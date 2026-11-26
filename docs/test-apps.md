# Ambulando Test

Use the **Ambulando Test** app for unattended UI work. It has the same feature code as the normal app, a persistent sample-data banner and a separate bundle/container/preferences domain. It always starts with local sample Tower, SSE, profiles and avatar transports, even without launch flags. Its synthetic credentials are fixture files in its own cache, never Keychain items. Missing fixture configuration stops startup before production storage is selected.

From the repository root:

```sh
./scripts/test-app.py mac --reset
./scripts/test-app.py iphone --reset
```

Omit `--reset` to keep sample drafts, navigation and synthetic credentials across launches. Reset removes only the test fixture directory and test preferences. The launcher builds, installs/opens the separate app, then requires a fresh fixture readiness marker within 45 seconds. `--timeout 10` changes the bound. `--missing-fixture --timeout 5` deliberately exercises startup refusal and must exit unsuccessfully. Build/launch evidence belongs in ignored `tmp/docs/handoffs/`.

The Mac app stays at `build/test-mac/Build/Products/Test/Ambulando Test.app` with bundle ID `studio.otherstuff.ambulando.mac.test`. The simulator app is at `build/test-ios/Build/Products/Test-iphonesimulator/Ambulando Test.app`, ID `studio.otherstuff.ambulando.native.test`. The launcher creates/reuses a dedicated **Ambulando Test iPhone** simulator; it never installs on a physical phone. It prints the exact app path, data container and build number. Normal Ambulando can stay installed and running alongside it.

Build alone with shared schemes `AmbulandoMacTest` and `AmbulandoTest`, configuration `Test`. The iPhone Test configuration only supports the simulator. These schemes compile `DEBUG AMBULANDO_TEST`; do not manually override compilation conditions. Existing `Ambulando` scheme UI testing now uses Test by default; normal Run/Archive remain Debug/Release with production authentication. Example focused UI check (substitute the dedicated simulator UUID):

```sh
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj \
  -scheme AmbulandoTest -destination 'platform=iOS Simulator,id=<uuid>' \
  -derivedDataPath build/test-ios -only-testing:AmbulandoUITests/ChatFlowUITests/testSendMentionAndReplyInThread test
```

Mac's existing in-process interaction harness accepts the Test window:

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression
```

The legacy upgrade-retention check intentionally exercises production auth/storage on a disposable simulator and requires explicit `AMBULANDO_UPGRADE_CHECK`; run it with normal Debug configuration, never the Test configuration. Sample checks validate UI and local pipelines only. Pete still verifies real Keychain login in the normal app every version; sample results do not validate Keychain, real Tower or real background execution.

The focused Mac NIP-44 check uses the real browser bridge and an in-memory synthetic identity:

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacNIP44Check
```

It reads a seeded self-encrypted kind 10318 fixture through JavaScript, edits and encrypts it, signs the saved event,
and decrypts the saved content again. It verifies the signature, native rejection of direct subframe bridge calls,
and cancellation of a pending request on an actual WebKit document commit. Add
`-AmbulandoMacNIP44HostedCheck` with `AMBULANDO_NIP44_TEST_ORIGIN=https://<preview-host>/` to repeat the fixture API roundtrip on the GitWorkshop preview origin and check
its client-side Settings route (requires network). Approval answers are driven by the
harness through the production broker. The check also approves encrypt and decrypt independently with Always allow,
flushes production LocalStore writes, reconstructs a new browser host, and verifies that revoking encryption
preserves decryption. It clears its site grants afterward.
It never publishes to a relay and does not validate Pete's real lists,
Keychain identity, a hosted GitWorkshop deployment, or installation on his MacBook.

The Mac Refresh data regression uses the isolated Test executable (no installer):

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacDataRefreshCheck
```

It exercises native refresh in an open conversation, duplicate requests, retained typed text and pending attachments,
remote replies and continuing live updates, error/retry, workspace selection and access-generation changes, minimum
window widths, browser form/history preservation and unsaved document editing. It uses synthetic fixture data;
it does not establish real-account acceptance on a user's Mac.

The focused Mac artefact regression uses synthetic records and the existing native window/editor hosts:

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoFixtureNappletTrust -AmbulandoMacArtefactWindowCheck
```

It checks the focused whiteboard toolbar, native mouse opening and Back, source-editor release,
repeat focus, draft checkpoint/close/reopen, independent main navigation, separate record windows,
and sandboxed HTML/registered napplet/private File entry paths. Registered iframe content is
verified through its loaded opaque sandbox and a native screenshot; this host’s in-process
accessibility tree does not expose that iframe text. The opt-in private File fixture
uses only synthetic tracker code/data. Window snapshots include the native toolbar and verify a
useful viewport. Capture the output in ignored handoff storage; it contains base64 screenshots.
Run `-AmbulandoMacDocumentWindowCheck` separately to validate the existing document popouts.

Popouts keep the original record and access boundary. Finish private napplet edits/saves or an
HTML source sheet before transferring it to a window. Native close/quit checkpoints board drafts,
blocks in-flight napplet saves, and asks before discarding an unsaved napplet. Selecting another
workspace hides an inactive window; normal access invalidation still destroys private web sessions.
Sample checks do not establish installation or real-account acceptance on a user's MacBook.

The generic workspace storage check takes a synthetic candidate and golden
fixture prepared independently of the native build:

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacStorageReportCheck \
  -StorageCandidate <candidate.html> -StorageGolden <workspace-report-storage-v1.json> \
  -StorageErrors <workspace-storage-errors-v1.json>
```

Place these synthetic inputs inside the Test app’s container cache so its
sandbox can read them. It uses the production opaque WebKit bridge with in-memory aggregate reads,
checks fresh reopen and widths 320/390/800, unavailable physical/provider values,
subset labels, and clearing the frame when workspace management is revoked.
The observer script is test-only; no live workspace or user credentials are used.
Core signed-transport tests separately validate fixed-route storage opt-in,
legacy behavior and HTTP 403 mapping. This check does not establish API activation
or installation on Pete's MacBook.
