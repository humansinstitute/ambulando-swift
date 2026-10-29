# Rich message layout

Native chat and document tables keep stable, bounded column widths and wrap text inside each cell. A table wider
than its message has a horizontal scroller; the enclosing conversation retains vertical scrolling. Each row is
measured at its own tallest wrapped cell, with borders filling that row. A short header does not inherit the height
of the longest body cell.

Rich bodies report their complete intrinsic vertical size. This prevents a horizontal table scroller from letting a
parent compress the body while fixed-height paragraphs paint outside their allocation, including over sender metadata.
The same SwiftUI renderer is compiled into iPhone, iPad and Mac. Parsing, stored message bytes and backend APIs are unchanged.

## Focused regression

Use the isolated Test apps described in [test-apps.md](test-apps.md). The Debug-only
`-AmbulandoRichMessageLayoutFixture` overlay is gated on an active synthetic fixture environment. It shows ordinary
messages around a long bold opening, a six-row table and additional paragraphs, links, a mention and a list.
The larger text button exercises accessibility text size. Debug geometry probes are disabled outside this fixture;
Release builds compile them away.

Run `AmbulandoUITests/RichContentUITests` with the `AmbulandoTest` scheme on the dedicated iPhone simulator.
The long-message test checks metadata clearance, intrinsic header height, viewport bounds, actual horizontal content
movement, the final paragraph and clearance before the following ordinary message. Attachments retain screenshots
and measured geometry at normal and larger text sizes. The other rich-content tests preserve heading, list, code,
mention, stored image and table coverage. The dedicated fixture flag must never be used with a real phone/account.

For Mac, build `AmbulandoMacTest` and run its executable with
`-AmbulandoFixtureReset -AmbulandoMacThreadRegression -AmbulandoMacRichFormattingCheck`.
The real-window check includes the same synthetic long message alongside its broader rich-content sample, at normal,
narrow and expanded window widths and larger app text. It checks horizontal bounds, stored body preservation, menus,
reactions and draft retention, and captures top/middle/bottom screenshots.

Simulator and synthetic-window checks establish layout behavior, not real-account acceptance. Signed installs,
installed build numbers and review of the original live conversation are separate release evidence.
