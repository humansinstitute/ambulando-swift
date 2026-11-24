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
data refresh do not reset it. The Mac uses an AppKit scroll view and stack with native buttons, explicit sizing
and an accessible control group. The local regression verifies real mouse clicks,
route-only reset, preserved same-screen offset (including adding/removing optional
controls) and fixed narrow/wide control widths.

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
build pass. The Mac native-container interaction regression passes. iPhone syntax parse passes; full iPhone build and UI execution are
blocked because Xcode offers no eligible iOS simulator destination. These are
outstanding acceptance requirements, not successful device validation.

Mac source build 117 fixes the physical button frames and icon/title drawing rows. AppKit's
symbol-dependent alignment insets previously expanded equal layout heights past the strip's clip
view; image-only buttons also centered their icon on a different row. Controls retain their existing
order, symbols, actions, scrolling, accessibility and route/offset behavior.

The fast geometry regression compiles the production strip into a standalone AppKit host:

```sh
swiftc -parse-as-library AmbulandoMac/MacNavigationStrip.swift \
  scripts/tests/mac-navigation-layout.swift -o build/mac-navigation-layout
build/mac-navigation-layout
```

It checks clipping, common icon/title rows, refresh spinner placement, selection and native actions
at narrow/wide widths in light/dark appearance. The isolated full-app navigation check above covers
real mouse routing and scroll-position preservation. iPhone/iPad strip rendering is unchanged.

Mac source build 118: the strip starts with the sidebar toggle, then Home, then the sections. It carries
no refresh control; refresh stays at Account › Refresh Data (⌘R) and on the thread and browser surfaces.
