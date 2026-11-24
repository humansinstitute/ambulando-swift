# iPad layout

The iOS target supports iPhone and iPad. iPad uses a full native scene in all four orientations and supports
resizable multitasking windows. The same identity vault, local store, navigation paths and drafts serve both devices.

At widths of 760 points or more, iPad shows a 280-point sidebar with sections and the shared workspace, scope and
channel navigation. The navigation toolbar button hides or reveals the column. Narrower windows use the existing
bottom section bar and navigation drawer. Each section's UIKit host remains mounted across width changes and section
switches, preserving its open screen, scroll position and composer. No separate tablet data model is used.

Chat and thread columns have an 860-point reading limit, including the composer. Document/task content and comment
fields use the same limit; identity and connection forms use 620 points. Lists, task boards and the full-scene browser
use their available pane width. macOS keeps its own window shell and layout.

`TabletLayoutUITests` checks portrait/landscape draft retention, keyboard visibility, section/browser return and compact
navigation on labelled local sample data. Run the tablet tests on an iPad simulator and `testPhoneKeepsCompactShell`
on an iPhone simulator. The compact test uses `-AmbulandoFixtureCompactWindow` with sample mode: a visibly labelled
420-point window harness, compiled only for Debug simulators. It does not test the system's Split View gestures.
Release/device builds cannot activate that harness or sample mode.

## Optional Chat navigation (iPhone/iPad source build 115)

Settings → Sections → **Show Chat** defaults off and uses the existing device-local
`sections.chat` preference. It controls both the compact scrolling section strip
and the wide tablet sidebar. Enabling it restores Chat immediately after Deck.
Disabling it keeps the active Chat host mounted, its conversation/draft, explicit
Deck/thread/message/notification/link entry and saved startup/back routing.
The Home globe and whole-strip scrolling are unchanged. Mac behavior is unchanged.

`NavigationStripUITests/testShowChatSettingRetainsConversationAndPersists` is the
focused Settings/draft/Deck-entry/relaunch acceptance case; run it on an iPhone
and a wide iPad destination. Existing navigation tests explicitly enable Chat
when they need its button. Also run the existing whole-strip and thread-focus
checks, including explicit links/notifications with Chat hidden.

Source parsing and a standalone shared AppStorage check pass (fresh OFF, all
optional-section orders, then ON and OFF across separate processes). These do
not establish iOS UI acceptance: this host lists the iOS SDK but the normal app
scheme reports only ineligible destinations with the platform missing. Full
iPhone/iPad build, narrow/wide Settings interaction, current focused-thread/draft
retention, notification/deep-link round trips and physical-device acceptance
remain open. No TestFlight build or installation is claimed.
