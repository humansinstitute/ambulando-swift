# Vendored from sol

These files are unchanged copies from the Ambulando web client (`sol`, MIT licence, see `../../LICENSES.md`), taken at
commit `c7fafcb34a7a35578e55e5f121dfa4c4ee75af3f` ("feat(canvas): add spatial board comments and threaded replies"):

| Here | sol |
| --- | --- |
| `board-editor/editor.js` | `src/canvas/board-editor/editor.js` |
| `board-editor/comments.js` | `src/canvas/board-editor/comments.js` |
| `board-editor/comments.css` | `src/canvas/board-editor/comments.css` |
| `board-comments.js` | `src/canvas/board-comments.js` |
| `board-scene.js` | `src/canvas/board-scene.js` |

They are the web's Excalidraw board editor surface (toolbar, drawing, library, image insert, spatial comments). It owns
no network or storage; `../main.js` connects it to the native app instead of the web Canvas page. To update, copy the
same paths from a newer sol commit, update the commit above and check that the message protocol in `../main.js` and
`Ambulando/Views/BoardEditorView.swift` still matches (`load`, `patch`, `flush`, `action-ui`, `comments`, `clear` in;
`ready`, `change`, `flushed`, `action`, `comment-op`, `error` out).
