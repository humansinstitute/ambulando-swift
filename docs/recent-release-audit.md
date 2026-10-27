# Recent native release audit

The floating New thread button was omitted from iPhone/iPad build 31. It was approved and written in an isolated
source branch, but never integrated or validated for that release. It was not a hidden setting or a sync failure.
Build 31's Deck has only the small Inbox-heading +; its filters and Search are separate rows.

## Scope and provenance

This audit covers the explicit Deck/composer follow-up and recent native releases 24–31 / Mac 14–22, including the
seven overnight feedback items, canvas editing and thread-header actions. Reference: current Ambulando `../sol`,
not the retired Flight Deck checkout. Existing broader parity gaps remain in [parity-matrix.md](parity-matrix.md).

- `7908759` labels iPhone/iPad 31 and Mac 22 and adds the overnight changes; `2d22c89` adds the thread-header menu
  without changing those numbers. Earlier Mac typography is `f1f8b45`; notification-tap repair is `0d0a5bf`.
- Earlier release evidence records iPhone 31 installed by normal update, with launch blocked while locked; Mac 22
  installed and running, signed universal package. These records establish historical availability, not a fresh
  live-account test. A build number alone does not identify the exact source: the menu landed after the 31 bump.
- The older isolated Deck/composer checkpoint is `6919992`, based on `3d2611b`, with Deck `ecc9775`, composer
  `f2ea3f5`, initial strip-height repair `2dc2ecf` and fixture interaction checks. None was an ancestor of build 31.
  Its viewer overlaps the later lightbox and must not replace that newer implementation wholesale.

## Confirmed omissions recovered

| Commitment | Build 31 / Mac 22 | Recovery behavior |
| --- | --- | --- |
| Floating New thread on every paging Deck card | Missing on iPhone/iPad | 56pt + at lower right above dots/navigation; existing Inbox + retained; hidden with keyboard; scroll content leaves room below its last row |
| Unambiguous create target | Scope/Home silently chose first eligible channel | Current channel or sole eligible channel selected; otherwise Choose channel before composer/Send; scope changes reconcile selection |
| Compact Inbox controls | Separate filters and Search rows | Four visible type filters and flexible Search share a row; accessibility text sizes keep a separate search row |
| Comfortable tappable composer thumbnails and shared strip | Small fitted uploaded thumbnails, separate mention/photo/upload rows; staged photos lacked preview | 72pt cropped tiles with separate 44pt Remove; mentions/photos/files wrap together in a bounded two-line scrolling strip; existing lightbox previews images |

Mac intentionally keeps its existing Deck-header create control: the floating button commitment applies to paging
Deck on iPhone/iPad. Mac receives the shared composer strip, tiles, previews and explicit channel selection.
Record-mention identity/icons from build 31 are retained; old branch assumptions that every mention is a person
must not be reintroduced. Storage, signing, drafts, outbox and network contracts are unchanged.

## Loading repair found during recovery validation

A cold uploaded thumbnail could stay at “Loading image…” after upload. The renderer relied on throttled global
sync status, while attachment completion actually announces a local `messages` change. A fast completion could
be missed. The image now subscribes to the existing coalesced local change stream before its first cache probe,
rechecks when attachment completion touches its workspace, and stops listening once decoded. No polling or new
network contract is added. A completed bounded decode is accepted only for the same current cache key, avoiding
an additional cancellation path that could discard the bitmap after the file was already found.

Scope/Home channel choice is a visible native list within the composer, with stable channel-row identities. This
avoids a secondary presentation for choosing a target; no field or Send appears until a channel is selected.

## Recent feature comparison

| Feature / commitment | Current web | iPhone / Mac source through 31 / 22 | Audit outcome |
| --- | --- | --- | --- |
| Messages-only navigation and conversation reply entry | Messages with threads | Both implemented | Delivered in recent release; existing fixture evidence, no fresh live-account claim |
| Image lightbox | In-app modal | Phone full screen; Mac window overlay | Delivered; intentional platform presentation difference |
| Stacked composer tools / editable inline image placement | Stacked tools and editable storage Markdown | Both implemented, image appears once | Delivered; recovered strip preserves placement and upload pipeline |
| Blank reopened thread / reading position | Web list implementation | Bounded measured 50-message native page | Delivered native remedy; not a dropped web renderer |
| Desktop canvas windows / mobile bottom chrome | Desktop window/mobile canvas controls | Mac independent windows; iPhone hides global section bar | Delivered recent source, with fixture evidence |
| Canvas shapes, text, frames, groups, whiteboard create and populated pickers | Rich canvas editor | Implemented subset on both native platforms | Partial parity, explicitly documented below |
| Record @ lookahead and canonical tags | Broad record lookup | People, agents, tasks, docs, chats, channels, scopes | Delivered subset; flows/opportunities not stored natively |
| Thread-header menu | Includes rename/archive and message actions | Get it done, Copy, Autopilot Link, FD Ref, author Delete | Delivered subset; Rename/Archive remain pending native writes |
| Automatic text attachments and versioned text editor | Supported | Implemented in 24 / 14 | Delivered earlier; preserved |
| Browser favourites | Supported | Device-local favourites in 24 / 14 | Delivered earlier; intentional device-local storage |
| Durable notification inbox / visible OS push | Web inbox and own delivery mechanism | Both inboxes; iPhone APNs registration, no Mac push entitlement | Delivered inbox; OS delivery depends on provider/configuration; Mac push unsupported currently |
| Channel-composer beachball | Separate renderer | Draft ordering fixed in 29 / 19; real-account hang not reproduced | Unresolved report, not claimed fixed by this audit |

## Explicit remaining work

Safe Home startup after an unclean exit/update and Settings Clear drafts are also still pending. The preserved
`b36348b` checkpoint is not in current main; its task records incomplete startup/shell/composer integration and
validation. This is a confirmed held feature with a separate concrete pickup, not included in the Deck recovery.
No drafts are automatically deleted.

Advanced canvas undo/redo, group-member/multi-select movement, freehand, arrow bends, scope-first remote HTML/board
picker and naplet minimise/full-screen chrome remain native gaps. Flow/opportunity mentions and native thread
Rename/Archive remain pending. These are existing documented limits, not new omissions inferred from this report.
The overall native parity table contains further older scope/access-management limits. Android is outside this audit.

## Validation and availability

See the release handoff/task for exact source revision, tested build numbers, signature/package hashes and observed
install status. Source, dedicated Test app, normal installed app and TestFlight are distinct delivery states. Sample
checks do not establish real Tower, Keychain, APNs provider delivery or a remedy for the unreproduced Mac hang.
