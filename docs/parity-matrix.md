# Parity matrix: Ambulando web (sol) → native iPhone

This table shows which Ambulando web features exist natively today, which work
package (WP) delivers each one, and which will stay web content or out of scope.
It is updated at every package handoff. The Status column states only what has
evidence behind it.

Status values (this file is updated only after validation evidence exists):

- **Delivered:** implemented and tested. The "Evidence" column says whether that
  means unit tests, the simulator or a live backend.
- **Planned:** scheduled in the named package and not started.
- **Web content:** the record itself is an HTML document (for example an HTML
  artefact or a WApp's own UI). It opens in a labelled web view, the surrounding
  navigation stays native, and it is not counted as native parity.
- **Proposed later package / proposed deferral:** this is the worker's proposed
  scope, not a decision Pete has approved. These items are not excluded
  permanently, and none is treated as web by default.
- **Unsupported:** needs a platform or server capability that does not exist.

| Web feature (sol) | Native surface | Pkg | Status | Evidence / note |
| --- | --- | --- | --- | --- |
| Ambulando theme, light/dark, logo | `Amb` tokens, app icon, passage mark | WP2 | Delivered (simulator) | Tokens from `ambulando-tokens.css`; artwork hash-matched to approved `passage-master.png`; launched on iOS 26.3 simulator |
| Identity import (nsec) and lock | PIN-sealed vault, per-install Keychain secret | WP2 | Delivered (unit tests, host + simulator) | Public NIP-19 test key only; no existing key read |
| NIP-98 request signing | `TowerClient` exact-body hash, redirect refusal, HTTPS-only | WP2 | Delivered (unit + live) | Verified with secp256k1 and cross-checked against nostr-tools; live Tower accepted a signed `GET /workspaces` from the public test key (HTTP 200, 0 workspaces) |
| nStack service descriptor | `/.well-known/nstack.json` reader | WP2 | Delivered (unit + live) | Opt-in live read: Tower available, `https`+`nip-98`, no FIPS service |
| Workspace discovery and selection | Connect screen, workspace menu, persisted selection | WP2 | Delivered (stub-transport end-to-end tests) | A real member's workspace list was not exercised: that needs the user's own identity imported on a device |
| Scope and channel navigation | Native scope sections and channel list from SQLite | WP2 → WP3 | Read path delivered (stub-transport tests) | Channel screen states that history arrives in WP3; scope order, collapse and pins in WP3 |
| Chat history (channels, threads) | Native message list, stable scroll | WP3 | Planned | |
| Send chat (kind 33358 + NIP-98) | Composer + durable outbox | WP3 | Planned | Signer already implemented and tested in WP2 |
| Drafts per channel | SQLite drafts, debounced | WP3 | Planned | |
| Mentions (render, people/agent picker) | Native tokens + picker | WP3 | Planned | |
| Image attachments in chat | PhotosPicker, privacy-stripped PNG | WP3/WP4 | Planned | Reuses NoteToSelf pipeline |
| Reactions, edit, delete message | Context menu | WP4 | Planned | |
| Inbox / Deck attention | Native inbox feed | WP4 | Planned | Inputs: mentions, assigned tasks, view states |
| Tasks list/board, detail, state, comments | Native list, swipe state, detail | WP4 | Planned | Board as segmented columns; calendar deferred |
| Documents list, read | Native Markdown render | WP4 | Planned | |
| Document edit | Plain-text Markdown editor with edit lease | WP4 | Planned | The web rich editor is not reproduced; this is a documented gap |
| Document comments | Native thread | WP4 | Planned | |
| Files list, preview, download, upload | QuickLook, background URLSession | WP4/WP5 | Planned | |
| Local search | SQLite FTS | WP4 | Planned | |
| Background refresh | BGAppRefreshTask + cursor resume | WP5 | Planned | Opportunistic; iOS controls scheduling |
| Foreground live updates (SSE) | Foreground-only stream, cursor recovery | WP5 | Planned | No suspended SSE |
| Retry, conflict, offline writes | Outbox backoff, row_version guards | WP3/WP5 | Planned | Row-version upsert guard delivered in WP2 |
| Performance instrumentation | Signposts, main-actor probe, storm budget tests | WP2 → WP5 | Core storm budget delivered (host + simulator) | UI hitch, keystroke and launch metrics in WP5 |
| Context tree (outline and visual) | Native outline, then native graph | Later package | Proposed later package | Not dismissed as web; needs its own native slice after WP4 |
| Canvas and naplets | Native canvas surface | Later package | Proposed later package | Canvas layout and naplets (tasks, docs, chat) can be native; only embedded HTML naplet content is web |
| Excalidraw boards | Native viewer or labelled web view | Later package | Proposed later package | Needs a decision between native rendering of the saved scene and a labelled web view |
| HTML artefacts | Labelled web view | Later package | Web content | The artefact itself is an HTML document; the surrounding navigation stays native |
| WApps / Toolbox | Native list, labelled web view for each WApp | Later package | Proposed later package | WApp UIs are web documents that their publishers own |
| Pipeline viewer | Native read-only view | Later package | Proposed later package | |
| Agents / Autopilot sessions view | Native read-only list | Later package | Proposed later package | Needs review of the Autopilot connection contract |
| Workrooms, reports, jobs, opportunities | — | Later package | Proposed deferral | Awaiting Pete's prioritisation |
| Daily scope, audio notes | — | Later package | Proposed deferral | Awaiting Pete's prioritisation |
| Hosted workspace signup, billing, legal | — | Later package | Proposed deferral | Web onboarding stays authoritative until decided otherwise |
| Push notifications | — | — | Unsupported | Tower has Web Push (VAPID) only; APNs needs separate server work |
| FIPS transport | — | — | Unsupported natively | WMapp-shell capability; native-ip is HTTPS-only and never silently falls back |
