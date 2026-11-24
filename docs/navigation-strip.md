# Workspace navigation strip

Mac source build 113 and iPhone source build 114 add a leftmost Home globe inside
one horizontally scrolling section strip. Home opens Deck for all accessible scopes
and channels in the current workspace, clears the section lock and closes a focused
conversation through existing navigation. The globe is selected only at workspace
Deck root. Existing sections keep their order, icons and routing.

Phones show approximately four and a half controls. Wide windows retain comfortable
control widths rather than stretching the row. Mac sidebar and refresh controls
scroll with the section controls. The existing Mac placement above the content and
phone bottom safe area/keyboard behavior remain.

The scroll position starts at the left on appearance and changes of visible route,
workspace, context or focused conversation. Ordinary live data updates and explicit
data refresh do not reset it. The Mac uses native AppKit button tracking. Local mouse-event validation currently
fails: hit testing resolves to the underlying content list even at the Home
button’s native and accessibility frame. Mac interaction acceptance is blocked
until the horizontal-scroll hosting boundary is corrected and the regression passes.

Focused checks:

- `NavigationStripUITests/testWholeStripScrollsAndNavigationResets` uses local iPhone
  fixture data to check sizing, globe selection, whole-strip swiping and route reset.
- Run the isolated `AmbulandoMacTest` with `-AmbulandoFixtureReset
  -AmbulandoMacThreadRegression -AmbulandoMacNavigationStripCheck` for real local
  mouse clicks, workspace Home semantics, view locks and route/data identity.

Local fixtures and builds do not establish physical-device installation or live
account acceptance. Pete pulls GitHub main and builds on his MacBook separately.

Validation for this source revision: core XCTest (830 cases, five skips, zero
failures), Swift Testing (60 cases), installer regressions (92 cases) and Mac Test
build pass. iPhone syntax parse passes; full iPhone build and UI execution are
blocked because Xcode offers no eligible iOS simulator destination. These are
outstanding acceptance requirements, not successful device validation.
