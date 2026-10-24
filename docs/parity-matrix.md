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
| Scope and channel navigation | Native scope sections and channel list from SQLite; personal scope order (`GET /me/scope-order`); collapse on device; chat path restored per workspace | WP2 → WP3 | Delivered (unit + simulator UI automation on sample data) | Order, collapse and its relaunch persistence, and workspace switching without cross-workspace rows are covered by UI tests. Personal **pins** are not delivered: Tower exposes them only through the record-sync `personal_pin` family (follow-up task) |
| Chat history (channels, threads) | Native channel feed (thread roots + reply counts) and thread view, from SQLite | WP3 | Delivered (unit + simulator UI automation on sample data) | `GET /channels/:c/messages` forward pages (≤ 200) with a resumable last-page cursor and range reconciliation; `?thread_id=` on thread open; thread titles from `/threads`. Opens at the newest message; follows your own sends. Live deltas/SSE are WP5. **Not exercised against a live Tower with a member identity** |
| Send chat (kind 33358 + NIP-98) | Composer → SQLite outbox → `POST /channels/:c/messages` | WP3 | Delivered (unit + simulator UI automation on sample data) | Trimmed body signed (kind 33358, workspace/channel/thread tags), request frozen once and reused with the same `client_request_id`; fresh NIP-98 per attempt; replay, retryable (network, 5xx, 408/429, first 401s) and permanent (`idempotency_conflict`, `thread_not_found`, `channel_not_found`, 403, validation) outcomes; per-conversation order; locked compose waits for unlock; survives relaunch. **No live send performed** (no user identity; public test key never used for writes) |
| Drafts per channel | SQLite drafts per connection/workspace/channel/thread, debounced off-main | WP3 | Delivered (unit + simulator UI automation) | Kept across navigation and relaunch; moved into the outbox in one transaction on send; restored by Edit on a rejected send |
| Mentions (render, people/agent picker) | Picker from `GET /members`; `@[Label](mention:type:npub)` rendered as chips | WP3 | Delivered (unit + simulator UI automation on sample data) | Visible token and structured `mentions` entry derive from one `{type, npub, label}`; edited-away mentions are not sent. Record references (`mention:document:…`) render as labels but do not navigate yet |
| Image attachments in chat | PhotosPicker, privacy-stripped PNG | WP4 | Planned | Moved to the files work (needs storage prepare/upload); reuses NoteToSelf pipeline |
| Reactions, edit, delete message | Context menu | WP4 | Planned | Unsent messages can already be edited or discarded; editing sent messages (kind 33358 with `message_id`/`revision`) is not built |
| Inbox / Deck attention | Native inbox feed | WP4 | Planned | Inputs: mentions, assigned tasks, view states |
| Tasks list/board, detail, state, comments | Native list, swipe state, detail | WP4 | Planned | Board as segmented columns; calendar deferred |
| Documents list, read | Native Markdown render | WP4 | Planned | |
| Document edit | Plain-text Markdown editor with edit lease | WP4 | Planned | The web rich editor is not reproduced; this is a documented gap |
| Document comments | Native thread | WP4 | Planned | |
| Files list, preview, download, upload | QuickLook, background URLSession | WP4/WP5 | Planned | |
| Local search | SQLite FTS | WP4 | Planned | |
| Background refresh | BGAppRefreshTask + cursor resume | WP5 | Planned | Opportunistic; iOS controls scheduling |
| Foreground live updates (SSE) | Foreground-only stream, cursor recovery | WP5 | Planned | No suspended SSE |
| Retry, conflict, offline writes | Outbox state machine with scheduled backoff; row_version guards | WP3/WP5 | Chat writes delivered (unit + simulator UI automation); conflict policy for edits is WP5 | Network return and foreground resume retry; per-key engine backoff; a reserved engine slot keeps user sends ahead of bulk catch-up |
| Performance instrumentation | Signposts, main-actor probe, storm budget tests | WP2 → WP5 | Core storm budget delivered (host + simulator). UI typing-under-storm **measured on the simulator; the 50 ms max target is not met** (a limitation carried to WP5 physical-device profiling) | 20k-row storm while typing 64 characters in the chat composer (simulator): no dropped characters; main-actor p99 4.7–10.6 ms and max 53–60 ms over 5 full-suite runs. The no-write control run (same typing and window) shows p99 7.7–25.5 ms and max 53–70 ms, so the single ~55 ms stall appears to come from keyboard/UI work rather than sync. This is a measured comparison, not proof of zero sync impact or of the UI budgets. The UI test's 100 ms bound is only a freeze guard, not a performance target. Device hitch, keystroke-to-render and launch metrics remain WP5 |
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
