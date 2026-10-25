# Board editor (embedded Excalidraw)

Excalidraw boards on a canvas are edited in the web app's own editor, embedded in the native apps. This folder builds
that one page; the rest of the app stays native.

- `web/sol/`: the web client's board editor (Excalidraw toolbar, drawing, library, images, spatial comments), vendored
  unchanged with its provenance in `web/sol/PROVENANCE.md`.
- `web/main.js`: connects that editor to the app (`webkit.messageHandlers.board` out, `window.ambulandoBoard.deliver`
  in) in place of the web Canvas page's MessagePort. The page has no signer, keys or `window.nostr`, fetches nothing
  beyond its own files and cannot navigate.
- `package.json` + `bun.lock`: exact dependency versions. `LICENSES.md`: notices.

Build: `scripts/build-board-editor.sh` (needs [bun](https://bun.sh); installs the locked dependencies, then builds
`dist/`, about 21 MB of which 13 MB are Excalidraw's fonts, including the CJK face Xiaolai). Xcode runs
`scripts/board-editor-xcode.sh` for the iPhone/iPad and Mac app targets, which builds when the sources changed and
copies `dist/` into the app as `BoardEditor.bundle`. `dist/` and `node_modules/` are not tracked.

The app side is `Ambulando/Views/BoardEditorView.swift` (web view, bridge and navigation policy) and
`AmbulandoCore/Sources/AmbulandoCore/Surfaces/BoardEditing.swift` (all board reads, drafts, saves, versions and
conflicts, through Tower's file routes).
