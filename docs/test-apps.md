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
