# Chat text selection on Apple platforms

A rich message is one read-only selection document. Users can extend a standard selection across headings, paragraphs, lists, quotes, code and table cells. Selection stops at message boundaries. Documents retain their existing reader/editor.

The old renderer put every paragraph and table cell in a separate SwiftUI `Text`. `.textSelection(.enabled)` could not create a range across those views; iPhone SwiftUI text also lacked normal selectable-text behavior. A whole-card navigation button and row-wide context menu competed with the text gestures.

`RichBlocksView` now uses `ChatSelectionView` for chat. `ChatSelectionHTML` converts the existing parsed blocks into escaped semantic HTML. The embedded WebKit page provides native Mac drag selection and iPhone long-press handles. Plain iPhone messages use a lightweight non-scrolling `UITextView`; plain Mac messages retain a single SwiftUI text surface. Opening a thread uses its explicit reply/open-thread control. Message actions remain on the ellipsis, including its context menu. A long press on body text belongs to selection.

The conversation owns vertical scrolling. Rich pages report their content height with `ResizeObserver`; code and tables retain horizontal overflow. Pages share one nonpersistent WebKit data store so short-lived message views can share processes. Long conversations still paginate messages. WebKit has greater per-rich-message overhead than the old block renderer; large-scale process/memory profiling remains useful.

The clipboard contains the selected fragment, not Markdown source or the whole message. `text/html` retains headings, links, styles, lists and semantic table rows/cells, including partial boundary cells. `text/plain` uses tabs between table cells and newlines between rows; controls such as Copy code are omitted. The destination application decides which representation to use. Within-cell line breaks become spaces in TSV. Plain messages use platform copying.

Streaming updates replace only the body DOM. A selection is restored using UTF-16 offsets when the text through its end is unchanged. Earlier text edits clear the selection rather than selecting different words. Font, theme and table-scroll updates preserve the existing range. A WebKit process eviction can reset selection while recreating the read-only content.

Only generated, escaped HTML enters the page. CSP blocks network access, source scripts, forms and embedded external content. All navigation is cancelled; clicked approved links are routed through the app's existing URL/mention/wiki handling. Remote images remain links and are never fetched. Stored images use the authenticated file cache, are downsampled off the main actor and passed as data URLs. The page has no credentials or signer. Native accessibility retains semantic text, links, headings, table cells and controls.

## Verification

Run `scripts/tests/chat-selection.sh` on a Mac with a graphical login. It runs core renderer tests, then loads the shipped HTML and JavaScript in real WebKit. Checks cover partial paragraph/table ranges, prose-table-prose, nearly full message, Unicode, selected HTML/plain content, list/code handling, streaming preservation, theme/text size, narrow horizontal overflow, bridge events and the native system clipboard. Artifacts are ignored under `tmp/docs/handoffs/chat-selection/`.

`RichContentUITests` exercises the isolated iPhone sample app. `MacRichFormattingCheck` exercises an actual synthetic Mac conversation, including native selected-fragment copying, reactions, responsive layout, scrolling, draft retention and message menus. Its WebKit content check uses the rendered DOM because its in-process AppKit accessibility walker cannot traverse remote WebKit accessibility elements.

Physical-device acceptance should include Mac pointer drags in both directions across paragraphs and tables, iPhone handle extension across and beyond the visible viewport, VoiceOver selection/navigation, pasting into a spreadsheet and rich editor, and long conversations with many rich messages. Automated DOM ranges and a simulator do not establish physical-device verification or installation on another Mac.

## Body typography

Plain chat and the rich selection document share `NativeChatTypography`. Mac resolves the system body font (13 points on the currently tested system) and the app's text scale; its line advance follows SwiftUI's native text bounds without extra font leading, plus the chat line spacing. iPhone resolves `UIFont.preferredFont` with the view's actual Dynamic Type category, including local accessibility overrides. There is no separate WebKit size table. `ChatTextPalette` supplies the same body, muted and link colors as the native theme. Prose is regular weight; mentions retain their local emphasis and underline, Markdown keeps bold/italic, and headings/code retain their deliberate hierarchy and font family.

The host sends resolved size, line height, weight and colors to `chatStyle` as one value. Style changes update CSS without replacing message nodes or resetting the selected range. The page's initial fallback is replaced by the native metrics when navigation finishes.

The focused Mac selection check also compares normal and enlarged WebKit body metrics with an actual SwiftUI multiline plain-text view, checks light/dark and muted ink, and confirms inline link/mention/Markdown metrics and selection preservation. The isolated iPhone `RichContentUITests.testPlainAndRichTypographyMatchNativeAtNormalAndAccessibilitySize` compares the production `UITextView` and WebKit renderers at normal and accessibility sizes. These are local fixture checks; physical-device appearance and selection gestures still require hands-on acceptance.
