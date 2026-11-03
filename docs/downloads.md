# File downloads

File detail Download is an explicit save action. On Mac it copies checked bytes to the system Downloads
folder with the Downloads read/write sandbox entitlement. It never replaces an existing file: duplicate
names receive a numbered suffix before the extension. Completion shows the actual filename and Reveal in Finder.
On iPhone/iPad the same action opens the system file exporter and reports success only after its callback.
Cancelling the save dialog does not claim a save. Preview, Share and Mac Save As retain their existing uses.

The foreground operation uses the existing signed typed file object route, verifies content hashes and caches
checked bytes. It does not depend on a temporary download URL or confuse queue acceptance with completion.
A corrupt cache is refetched. Existing authentication, workspace boundaries and 100 MB typed-route limit apply.
Failed reads or disk copies show a retryable error; cancellation and a two-minute deadline release the busy state.
No app package is installed or launched by Download.

Verification:

```sh
swift test --package-path AmbulandoCore --scratch-path tmp/build/download-core --filter DownloadCopyTests
xcodebuild -project Ambulando.xcodeproj -scheme AmbulandoMacTest -destination 'platform=macOS' \
  -derivedDataPath tmp/build/download-mac -skipPackagePluginValidation ARCHS=arm64 build
# Dedicated sample app; never launches or replaces the normal app:
 'tmp/build/download-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoMacThreadRegression -AmbulandoMacDownloadCheck
```

The real-window Mac check saves synthetic binary bytes through File detail into the sandbox-authorized Downloads
folder, compares exact bytes, repeats for collision handling, injects an HTTP failure, checks busy cleanup and retries.
It removes only its uniquely named test files. Core checks cover failed authenticated reads, cache corruption,
byte preservation, collision handling and disk failures. The focused iPhone simulator UI test `WorkFlowUITests/testFilesDownloadAndPreview` opens the real system save
picker, saves, waits for success, and returns to preview. The exported `sync-results.txt` retains its name and
matches the verified cache bytes outside the app's sandbox cache. Cancelling the iPhone picker remains a separate
manual check; an initial automation attempt selected a hidden accessibility element and did not dismiss the picker.
These checks do not establish real-account native interaction or physical-device installation.
