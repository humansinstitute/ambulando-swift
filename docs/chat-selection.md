# Native chat rendering and selection limits

Mac build 88 restores the SwiftUI chat block renderer used before continuous rich selection.
The same chat path is compiled into iPhone and iPad. Chat no longer creates a WKWebView for each
rich message; the selection HTML, bridge and WebKit-specific fixtures/checks have been removed.
Documents retain their native reader/editor and other embedded app surfaces are unaffected.

Paragraphs, headings, lists, quotes, code, tables, stored images, links and mentions retain the prior
native rendering and controls. Code has its Copy action; wide tables/code scroll horizontally while
the conversation scrolls vertically. Plain messages again use selectable SwiftUI Text. Selection
is limited to individual native text blocks/cells and platform support; continuous selection and
HTML/TSV selected-fragment copying across blocks are no longer provided. Whole-message copying
remains available through message actions. Thread cards regain their prior navigation behavior.

Compatible typography from the follow-up is preserved: shared native theme colors, regular native
body font for plain and rich prose, app text scaling on Mac and Dynamic Type on iOS. Headings,
emphasis, inline code and mentions keep their existing native hierarchy. WebKit CSS metrics and
DOM-selection preservation checks do not apply to this renderer.

Pete reported periodic scrolling stalls and delayed thread opening after the selection change.
Per-message WebKit overhead is a suspected contributor, not a measured root cause. Removing the
path is an authorized rollback; local fixture success cannot establish real-account performance
or installation on Pete's MacBook. Pete must pull/build the pushed source and review rich history.

## Verification

Run focused core Markdown, rich-document, message-display and table-layout tests. Build
`AmbulandoMac` and `AmbulandoMacTest`. The isolated `MacRichFormattingCheck` checks actual native
rich content, scrolling at normal/narrow/expanded widths, larger text, menus, reactions and drafts.
It rejects embedded WKWebViews in the chat window. See [rich-message-layout.md](rich-message-layout.md)
for restored iOS geometry, intrinsic-size, horizontal-table and native selection UI checks.
Those tests are fixture evidence; device acceptance and timing comparisons remain separate.
