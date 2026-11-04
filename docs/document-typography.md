# Document typography

Mac build 76 and iPhone/iPad build 85 keep the small serif document title and use a
consistent body scale in document reading and editing. On Mac, paragraphs and list
markers use 15 pt text, with 22 / 19 / 16 pt body headings, all following the app's
text-size control. iPhone and iPad retain preferred body/title styles and Dynamic
Type; an open embedded editor receives updated sizes when Dynamic Type changes.
The document paper remains light in both chrome appearances.

The native reader is `RichBlocksView` with selectable `NSTextView` paragraphs on
Mac. It is separate from the embedded Tiptap editing page. AppKit bridges do not
publish a SwiftUI text baseline: aligning a list row by `firstTextBaseline` placed
its marker above a selectable paragraph. Document rows now align at the top, with
a scaled marker gutter and a separate content column for wrapped and nested items.
Chat retains its own baseline alignment and typography. Selectable and fallback
paragraphs now use the same document font, ink and line spacing; which paragraphs
have source anchors no longer determines their visual size.

The embedded editor explicitly uses outside markers and normalizes first/last
paragraph margins in list items. A second paragraph stays within its list item;
wrapped lines and nested lists retain their hanging indent. The content, anchors,
selection bridge, save protocol and stored documents are unchanged.

## Validation

Build the bundled editor and run its preservation, link and selection checks:

```sh
scripts/build-board-editor.sh
(cd BoardEditor && bun test test)
swift test --package-path AmbulandoCore --scratch-path build/core --filter 'Document|Markdown|SyncStorm'
swiftc -parse-as-library scripts/tests/document-typography-webkit.swift -o /tmp/document-typography-check
/tmp/document-typography-check "$PWD/BoardEditor/dist" /tmp
swiftc -parse-as-library scripts/tests/document-comment-webkit.swift -o /tmp/document-comment-check
/tmp/document-comment-check "$PWD/BoardEditor/dist"
```

The typography check uses the actual bundled page in local WebKit, without an app
account or network. It checks tight, loose and nested list geometry, wrapped text,
links, selection, caret insertion, snapshot/reopen, narrow geometry and larger text
with dark chrome. Heading variables now accept their numeric names (`h1`–`h3`),
so heading sizes follow body text scaling instead of silently staying fixed. It writes screenshots for personal inspection. Its 30 insertion
measurements are synchronous edit/layout timings, not keystroke-to-display latency.
Narrow Mac WebKit geometry does not establish iPhone hardware or keyboard behavior.
The native reader's baseline diagnosis also requires a native geometry check;
HTML geometry alone cannot verify that bridge.

Source/build checks do not establish installation on Pete's MacBook, real-account
save/reopen, physical iPhone behavior or authenticated acceptance. Preserve normal
accounts and drafts; do not use production app test modes or real-phone fixtures.
