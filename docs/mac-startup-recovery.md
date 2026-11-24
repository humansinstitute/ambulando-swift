# Mac startup recovery

The Mac opens the underlying workspace screen before reopening a saved conversation. A banner offers
**Resume saved thread**. Choosing it opens the normal Thread view with its existing Reply draft. Closing
the resumed thread returns to the screen underneath. Deliberately opening other threads still works normally.
The iPhone and iPad keep their existing automatic thread restoration.

Startup reads the saved thread route without deleting or rewriting it. Channel and reply drafts, staged
attachments, outbox messages, identity, connection and preferences keep their existing storage. Ignoring the
banner and quitting leaves the conversation available on the next launch. Resuming an older Chat-stack route
migrates that navigation on deliberate opening, so subsequently closing the thread stays closed.

This is a recovery mitigation for a reported Mac launch beachball over an empty Thread/Reply sheet. An empty
thread and a persisted relaunch passed the baseline fixture checks; the historical real-account hang was not
reproduced. The change avoids automatically mounting the saved thread during launch; it does not establish
or repair an underlying content-specific hang. If resuming still hangs, preserve the data and capture the
running Ambulando process with Activity Monitor's **Sample Process** for diagnosis.

## Focused regression

Build the isolated Test app:

```sh
xcodebuild -project Ambulando.xcodeproj -scheme AmbulandoMacTest \
  -destination platform=macOS -derivedDataPath build/test-mac \
  -skipPackagePluginValidation ARCHS=arm64 build
```

Run the executable with `-AmbulandoMacThreadRegression -AmbulandoMacStartupThreadCheck` and these additional
flags, in order, waiting for each process to exit successfully:

1. `-AmbulandoFixtureReset -AmbulandoMacStartupThreadSeed` seeds a channel draft, an empty thread and a reply draft.
2. `-AmbulandoMacStartupThreadResume -AmbulandoMacStartupThreadKeepDeferred` checks that launch leaves the channel
   usable, keeps the stored route and both drafts, and exposes the resume action. Run twice to cover ignoring it.
3. `-AmbulandoMacStartupThreadResume` presses the real resume button, verifies the reply draft, closes the thread
   and checks the channel draft. It also switches workspaces and back to check banner ownership. The button's
   accessibility action is exercised; external hardware key delivery is not established by this harness.
4. `-AmbulandoFixtureReset` exercises deliberate opening, native keyboard focus, editing, close/reopen and durable
   reply edits in fresh sample data.

Only the dedicated Test bundle uses a stable `startup-thread-regression` fixture namespace for this check;
ordinary regression runs retain disposable databases. The fixture reset applies only to isolated sample data.
The existing main-actor heartbeat and independent watchdog guard responsiveness. These checks do not prove a
real Tower round trip, Intel execution or recovery on the reporting Mac. Release installation and authenticated
live evidence must be recorded separately on the delivery task.

## Write readiness and event catch-up (Mac source build 117)

Workspace startup validates access and applies event catch-up before opening its write services.
Historical task/thread/document events can name a record already removed from Tower. Tower's
resource-existence authorization check returns **400 `resource-not-found`** before the route can
return 404. Native event materialization treats that exact response like its existing missing-record
case, removes the cached server copy and continues the batch. Other 400 responses, authentication
failures and server errors keep the cursor replayable. No pending outbox message, attachment,
identity or connection is reset.

A transient startup failure also receives up to three bounded retries. Successful revalidation
reopens the existing write fence and drains retained sends; workspace pause/lock invalidates the
retry. The permission fence is never bypassed. A permanently rejected startup remains visible as
an error rather than enabling writes.

The isolated Mac Test executable accepts these checks together with
`-AmbulandoMacThreadRegression` (run each as a separate process):

- `-AmbulandoMacMissingResourceStartupCheck`: historical task/thread 400 responses, a later valid
  incoming message, retained/new outgoing sends, real image prepare/upload/complete and a durable
  unsent image draft.
- `-AmbulandoMacWriteStartupRetryCheck`: one failed startup followed by recovered transport,
  automatic send recovery and retry of the retained image without a network-return notification.

Core `LiveSyncTests` cover cursor progress and refusal to skip other validation/authentication
failures. `DeckActivityTests` cover canonical thread cards before transcript hydration, current
activity ordering, channel boundaries and archive exclusion. Inbox merges thread metadata with
cached messages, keeping one card and leaving the normal transcript fetch to deliberate opening.
These paths are shared native code, so the behavior also applies to iPhone/iPad; the focused
interaction harness runs on Mac. Local synthetic transport evidence does not establish installation
or live authenticated behavior on another Mac.
