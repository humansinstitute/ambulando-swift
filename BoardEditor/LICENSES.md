# Editor page notices

The board and document editor pages (`dist/`, copied into the apps as `BoardEditor.bundle`) contain:

| Component | Version | Licence |
| --- | --- | --- |
| Ambulando web client (`sol`) board and document editor sources, vendored in `web/sol` | commit `c7fafcb` | MIT, © 2026 Wingman contributors |
| `@tiptap/*` (core, pm, starter-kit and extensions) | 3.27.1 | MIT, © 2025 Tiptap GmbH |
| `prosemirror-*`, `orderedmap`, `rope-sequence`, `w3c-keyname` (via `@tiptap/pm`) | as locked in `bun.lock` (sol's versions) | MIT, © Marijn Haverbeke and others |
| `marked` | 17.0.4 | MIT, © MarkedJS and Christopher Jeffrey |
| `linkifyjs` (via the Tiptap link extension) | 4.3.3 | MIT, © Hypercontext |
| `@excalidraw/excalidraw` | 0.18.1 | MIT, © 2020 Excalidraw |
| `react`, `react-dom` | 19.2.0 | MIT, © Meta Platforms, Inc. and affiliates |
| Excalidraw's bundled dependencies | as locked in `bun.lock` | as declared in each package (`node_modules/*/package.json`) |
| Excalidraw fonts: Excalifont, Virgil, Xiaolai, Nunito, Lilita One, Assistant, Cascadia Code, Liberation Sans | from `@excalidraw/excalidraw` 0.18.1 | SIL Open Font License 1.1 |
| Excalidraw font: Comic Shanns | from `@excalidraw/excalidraw` 0.18.1 | MIT |

MIT licence text (applies to each MIT component above with its own copyright line):

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
> persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
> Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

The SIL Open Font License 1.1 permits bundling the fonts with software; its full text is at
https://openfontlicense.org/open-font-license-official-text/.
