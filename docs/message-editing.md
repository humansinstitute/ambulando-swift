# Editing sent messages on Mac

The author's **Edit** action in the native Mac message menu or context menu turns the chat composer into an edit
composer, in both channel Messages and threads. **Editing message**, **Save** and **Cancel** appear above the field.
The ordinary reply stays in its own ComposerModel: text, picked mentions, staged attachments and finishing uploads
are not borrowed by the revision. Each revision gets separate native undo history. iPhone editing is unchanged.

Type `@` at the caret and choose a person or bot from the existing picker, using a click or the picker keyboard keys.
The revision field retains canonical Markdown, including full actor tokens, rather than reconstructing identities from
plain names. Repeated tags, record references, formatting and inline storage links round-trip without flattening.
Structured actor mentions come from the final canonical body; plain `@Name` does not infer an identity.

Existing attachment metadata stays intact because the message PATCH omits attachment changes. New image/file uploads
are not offered during editing; ordinary text paste remains available. Reply uploads continue to target the reply.

Each message version has a private persisted edit draft. Leaving the conversation keeps an interrupted edit for that
version. Cancel awaits preceding draft writes and clears only that revision; Save clears it after durable write-queue
acceptance. A newer version uses a separate namespace. A failed enqueue keeps the edit open; a queued server conflict
uses the existing recoverable write status. Cancel remains available if the author locks their identity while editing.

The existing native sender signs the normalized exact body with kind 33358, binding workspace, channel, thread,
message ID and next revision. The frozen request carries structured actor mentions; retries retain the same signed
request. Existing Tower author permissions, row-version and signature validation remain authoritative. Backend routing
and contracts are unchanged.

## Validation

Focused `MessageRevisionTests` cover picker completion, canonical formatting and suffix preservation, exact structured
identity, cryptographic revision verification and readback, removal/re-addition and edit/reply draft isolation.

The isolated macOS Test app's in-process AppKit check runs with:

```sh
xcodebuild -project Ambulando.xcodeproj -scheme AmbulandoMacTest -destination 'platform=macOS' \
  -derivedDataPath build/test-mac -skipPackagePluginValidation ARCHS=arm64 build
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoFixtureReset -AmbulandoMacThreadRegression -AmbulandoMacMessageEditCheck
```

It sends an untagged message, opens its real native menu, edits in the composer, types `@`, point-clicks a bot, saves
and reads back exact body, structured npub, context, attachment metadata and a fresh cryptographically verified
signature. Three save cycles check first-responder acquisition and actual AppKit key events after reopening. It also
checks Cancel/immediate reopen/typing, unchanged saved content, and restoration of the unsent tagged reply plus staged
attachment. Longer strings use NSTextView's native insertion path; menu and picker selection use hit-tested window
point events. Synthetic reply/attachment metadata is seeded only in the dedicated Test app. No external accessibility
permission, web renderer, iPhone simulator, real account or bot dispatch is used by this check.

Sample acceptance does not establish production Keychain behavior, authenticated Tower acceptance, Intel execution,
or installation on Pete's MacBook. Signed universal build and GitHub main delivery evidence is recorded on the release
task separately from the installed app and running app versions. Never quit the normal app for unattended testing.
