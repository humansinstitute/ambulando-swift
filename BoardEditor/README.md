# Embedded web editors (boards and documents)

Excalidraw boards on a canvas, and documents, are edited in the web app's own editors, embedded in the native apps. This
folder builds those two pages; the rest of the app stays native.

- `web/sol/`: the web client's board editor (Excalidraw toolbar, drawing, library, images, spatial comments), vendored
  unchanged with its provenance in `web/sol/PROVENANCE.md`.
- `web/main.js`: connects that editor to the app (`webkit.messageHandlers.board` out, `window.ambulandoBoard.deliver`
  in) in place of the web Canvas page's MessagePort. The page has no signer, keys or `window.nostr`, fetches nothing
  beyond its own files and cannot navigate.
- `web/document.html`, `web/document.js`, `web/document.css`: the document editor page (Tiptap with sol's schema,
  vendored unchanged in `web/sol/docs` and `web/sol/utils`). It talks to the app over `webkit.messageHandlers.document`
  (small messages) and `documentFile` (one pasted file per message) and `window.ambulandoDocument` in; it has no signer,
  keys, `window.nostr` or network (CSP `connect-src 'none'`), and the app refuses every navigation away from it.
- `web/document-mentions.js`: native-owned document `@` search bridge, ID-based insertion, accessible keyboard/touch picker, click/drag guards and navigation callbacks. It never posts agent instructions. Tests: `test/document-mentions.test.js`.
- `web/document-preserve.js`: lossless editing. Unknown nodes become kept atoms, unknown attributes and marks are added
  to the schema for that document, and unchanged nodes and marks are written back as the stored JSON; Markdown
  documents keep the source of unchanged blocks. Tests: `bun test` (`test/document-preserve.test.js`).
- `web/document-selection.js`: adapts sol’s selection-anchor helper for the native comment sheet. Rich selections use
  ProseMirror positions; Markdown selections use the saved source line and quote. See `test/document-selection.test.js`.
- `package.json` + `bun.lock`: exact dependency versions (Tiptap, ProseMirror and marked pinned to sol's lockfile).
  `LICENSES.md`: notices.

Build: `scripts/build-board-editor.sh` (needs [bun](https://bun.sh); installs the locked dependencies, then builds
`dist/`, about 21 MB of which 13 MB are Excalidraw's fonts, including the CJK face Xiaolai). Xcode runs
`scripts/board-editor-xcode.sh` for the iPhone/iPad and Mac app targets, which builds when the sources changed and
copies `dist/` into the app as `BoardEditor.bundle`. `dist/` and `node_modules/` are not tracked.

The document editor's app side is `Ambulando/Views/DocumentEditorWeb.swift` (web view, bridge, navigation policy) and
`Ambulando/Views/DocumentEditing.swift` (lease, drafts, saves, uploads, images). The board editor's app side is `Ambulando/Views/BoardEditorView.swift` (web view, bridge and navigation policy) and
`AmbulandoCore/Sources/AmbulandoCore/Surfaces/BoardEditing.swift` (all board reads, drafts, saves, versions and
conflicts, through Tower's file routes).
