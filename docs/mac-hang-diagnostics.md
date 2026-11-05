# Mac responsiveness and recurrence evidence

Mac build 79 reduces work in the UI update path during split-divider tracking. A workspace entry computes its immutable boundary identity once. Native message/thread action buttons update their action closures normally, but skip unchanged accessibility metadata setters. On Mac, the Deck Inbox behind a focused/new thread keeps its rows and reading/filter state while deferring ordinary feed-query updates. Access invalidation stays live; closing the modal always reloads the feed. Network sync, conversation queries, activity deadlines, drafts and menu actions continue. iPhone/iPad retain live Inbox behavior and share the identity optimization.

These are measured mitigations, not proof that every persistent SwiftUI hang is fixed. A busy SwiftUI/AttributeGraph/accessibility stack inside `NSSplitView.mouseDown` identifies the interval being sampled, not the cause or recovery time. A hang report's duration is its observation window. Inspect the process lifetime and time since wake separately before attributing a failure to startup or wake.

## Build 84: persistent popup controls

The build 80 recurrence places all 22 main-thread samples in SwiftUI graph updates, with
`AppKitPopUpAdaptor` and accessibility label resolution prominent. The 17.18-second report
window is not the total hang length. Unlike the earlier split-view-tracking report, these
samples show a normal run-loop graph transaction; resizing is a reported recent action,
not a proven trigger. Stabilizing channel-query identity in build 80 did not eliminate it.

The remaining persistent popup controls in the workspace footer, stacked workspace options
and Deck Inbox header now use stable buttons with native menus. The workspace options and
Inbox reuse the AppKit action button; the footer uses a plain labelled SwiftUI button and
a noninteractive AppKit positioning anchor. Each refreshes current closures but builds its
`NSMenu` only on an explicit click/accessibility press. The footer keeps its visual label
and an explicit button accessibility label;
menu item labels no longer participate in SwiftUI's popup accessibility graph during resize.
iPhone/iPad keep their existing SwiftUI menus. This is a focused mitigation with moderate
cause confidence, not proof against every framework hang or real-account recurrence.

The divider regression additionally asserts no `NSPopUpButton` in the tested Deck/sidebar,
stable workspace anchor/Inbox native button identity, exact alternating channel selection after
drags within two seconds, no lazy-menu opens during resize/navigation, and actual workspace
collapse/expand and Inbox mark-read menu actions. Its synthetic incoming updates, draft and
tracking heartbeat checks remain enabled. Run the bounded check without the soak flag.

## Bounded local diagnostics

The Mac app starts a half-second heartbeat in common and event-tracking run-loop modes. An independent utility queue writes one record after a heartbeat has been absent for at least four seconds, including when the main thread never recovers. Wake resets the heartbeat. Eight fixed cache slots, each limited to 16 KiB, bound disk use; a process writes at most eight records. The files are local only and are never uploaded automatically:

`~/Library/Containers/studio.otherstuff.ambulando.mac/Data/Library/Caches/AmbulandoHangDiagnostics/hang-0.json` through `hang-7.json` (sandboxed app).

Records contain the build, timestamp, heartbeat delay, last run-loop mode, fixed UI/query counters, current message-row counts, and a rate-limited UI-owner stack breadcrumb. No message text, account/workspace/thread IDs, URLs, credentials, signatures or drafts are recorded. Home-directory prefixes in symbol strings are replaced with `~`.

**The breadcrumb is the last measured UI owner, not a stack sample of the hung main thread.** Its age is recorded. Query-start/load counters distinguish an unfinished local query from completed reads; row counts distinguish an empty result from materialized content. They do not prove which control caused a stall. The operating system may suspend the whole process or evict caches; absence of a diagnostic does not prove absence of a hang.

For a recurrence, retain these files and obtain a macOS process sample while the app remains frozen, with the exact time/build and whether the divider button was held or released. Sample only the identified Ambulando process, and keep reports private: system samples may contain local paths. Do not reset account data or restart another user's app to collect evidence.

## Isolated regression commands

Build the separate Test bundle with `./scripts/test-app.py mac --reset`. Quit only that Test bundle before launching its executable with these flags:

```sh
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoFixtureReset -AmbulandoMacThreadRegression \
  -AmbulandoMacDividerCheck -AmbulandoFixtureAgentActivityStall
```

For a smaller menu-only check, add `-AmbulandoMacPopupCheck` to the same command. It verifies
workspace collapse/expand and Inbox mark-read through real native menu tracking, stable button identity,
and absence of persistent popup controls, then exits before divider/traffic checks.

The check calls the real `NSSplitView.mouseDown` with queued mouse-drag/up events, verifies actual divider movement, mouse-up-to-return latency and a common/event-tracking timer heartbeat (both under two seconds), and covers incoming replies/Inbox activity, thread presentation, native menu tracking/actions, live-activity expiry, menu identity and draft retention. Calling the divider directly under a modal deliberately stresses otherwise shielded background layout; it does not remove the product's input shield. It also verifies the background Inbox stops reloading for ordinary changes and catches up after closing.

Add `-AmbulandoMacDividerSoak` for ten minutes of further incoming activity, repeated modal/menu/draft checks and ten app-local simulated wake/foreground cycles. This does not sleep the machine and is not a physical sleep/wake test. A separate run with `-AmbulandoMacHangDiagnosticCheck` instead of the divider flags deliberately blocks only the Test app's main thread for 5.5 seconds, verifies a bounded record is written during the stall, and checks heartbeat recovery. Never run fixture checks against a real account.

Run timing checks without simultaneous compiler load. Inspect individual cycle timings and watchdog output; do not present a completed source build or fixture run as installation or real-account acceptance on another Mac.
