# Native review fixes (Mac build 112, iPhone/iPad source build 113)

Channel artefacts retain their document structure, show explicit locked states, refresh Files on unlock,
and show a useful message when a filter has no matches. Documents and File artefacts are ordered together
by update time. File classification happens in the store snapshot; File rows show channel and timestamp.

HTML recovery drafts now use the same identity/origin/application/workspace boundary as board drafts.
An older draft for the exact connection/workspace/File can be loaded explicitly for review; it is never
silently imported into an application boundary, and its original file is kept. Sample fixtures never read
production legacy drafts. Loading source for review does not publish it.

HTML and whiteboard screens offer **Download or share original**, opening the existing File controls:
checksum-checked Download, cached Preview/Share, and Mac Save As. This exports the saved original File,
not unsaved editor changes or a flattened rendering of a packaged HTML artefact. Save a revision first
to export new edits. Existing verified cache checks and bounded/cancellable exports remain in use.

Workspace and File app launchers appear on Mac Deck as well as Toolbox. Launcher discovery refreshes on
opening/returning to an active section and foregrounding, or explicitly with Refresh. It has no periodic
list timer. Workspace installation metadata uses a keyed SyncEngine job with existing read backoff.
File launcher discovery verifies a File and its code once per attempt; unchanged in-memory descriptors
are reusable only when File identity, current version, digest and canonical row match. Missing version/digest
metadata causes fresh verification. Cached labels never authorize code execution; opening and using an
app still perform the existing online authority checks. Foreground app authority timers remain, while
background store invalidations defer authority reads until foreground return.

Mac channel access loss already removed authoritative local records. The same confirmed complete-list
reconciliation now removes associated cache bytes after commit. Cache writes share the writer's revocation
generation, so an earlier download cannot recreate removed bytes after cleanup. Shared accessible message,
document, comment and task references are retained, as are recovery references and originals needed by
pending commands or exact board/HTML drafts. Drafts, outbox, upload staging and recovery originals are
not deleted. Cleanup applies to newly reconciled revocations while the File/message ownership metadata is
still available. Historical orphan bytes whose records were removed before this release cannot safely be
attributed retroactively and remain until workspace disconnect or system cache eviction. A cleanup failure
records a generic local diagnostic and cannot suppress authoritative
access-loss notification. No Android retention policy is changed by this Swift release.

Tasks consume Escape only when cancelling a non-busy selection. Shared iPhone Deck dots have 44-point
hit areas. Local Search labels HTML/whiteboard results and offers artefact-type and current-channel filters.
Mac Refresh Data now includes File metadata in Artefacts and workspace app listings on Deck/Toolbox.

## Review disposition

| Finding | Native disposition |
| --- | --- |
| #1 marketing assets/headers; W1–W3 web client | Not applicable to Swift native; separate repositories and delivery owners. No public exposure or web deployment is claimed. |
| #2 doctype/bootstrap insertion | Fixed in asset hydration and the final sandbox document builder. Existing full documents retain their doctype/head/body rather than being embedded inside another body. Real WebKit regression checks `CSS1Compat`, content and one HTML element. |
| #2 locked HTML spinner | Fixed; HTML/v2/v3/report viewers provide explicit locked or wrong-workspace errors. |
| #2 unlock refresh | Fixed for Docs/File metadata and whiteboard viewer loading. |
| #2 filtered empty state | Fixed using filtered document and File rows. |
| #2 unisolated HTML drafts | Fixed, with explicit legacy review and originals preserved. |
| #2 repeated classification, chronology and row metadata | Classification moved into snapshot, rows merged chronologically, channel/time added. File-level dirty badges deferred: board/HTML editor recovery is not represented by the document-draft table; a false clean/dirty badge would be misleading. Existing editor draft notices remain. |
| #2 exports/offline | Original verified export controls restored. General offline reopening of HTML/boards deferred: the projected package, immutable version/assets and current authority need one explicit policy. Existing File cache integrity and board recovery remain; executable apps do not gain offline authority. |
| #3 hidden launcher polling | Fixed: no 30-second list loop, with section/card and scene gates. |
| #3 shared sync ownership/duplicate verification | Shared runtime list uses keyed bounded refresh/backoff; File discovery uses a bounded foreground job, one exact-row descriptor and version/digest metadata reuse. Foreground version checks, command responses, uploads and runtime authorization remain direct where the architecture explicitly exempts them from forced workspace refresh. No broad network rewrite. |
| #4 channel cache revocation | Fixed within the existing Mac purge contract, with shared/recovery retention, postcommit error isolation and late-download protection. Filesystem failures can leave bytes behind and are recorded locally; no success is fabricated. |
| #5 Mac v2/v3 Deck parity | Fixed using the existing launchers/hosts. |
| #5 Toolbox regrouping/shared WebKit host | Deferred: label regrouping and host consolidation are separate UI/trust-boundary work, unnecessary for the verified defects. Existing protocol-specific authorization and dirty-close behavior remain. |
| #6 AppModel/large-view decomposition | Deferred: no evidence that a broad observation rewrite is necessary for these defects. The model change only binds each existing workspace cache and recovery directories to its writer. |
| #6 Safe Home/Clear Drafts | Deferred-thread startup recovery already exists (`mac-startup-recovery.md`). A broader Safe Home mode and explicit Clear Drafts remain deferred; this release preserves drafts instead of integrating a destructive recovery command from a held checkpoint. |
| #7 Escape and Deck targets | Fixed. The dot sizing affects shared iPhone code; Mac has a dashboard, not pagination dots. |
| #7 Search | Human-readable artefact labels and local type/channel filters fixed. Thread-title FTS migration and indexing cached HTML text deferred: these require index/backfill and content/authority policy beyond display filtering. |
| #7 new shortcuts/cleanup workflows | Existing task archive/bulk status controls already exist. Quick Channel/Record Jump, New Thread/New Artefact/New Task menu shortcuts, thread archive and task move/delete remain deferred: new navigation/focus contracts and typed mutation UX require separate implementation and acceptance. Search remains on Command-F. |

## Validation and delivery

Run the core suite, focused renderer/recovery/cache tests and installer regressions:

```sh
swift test --package-path AmbulandoCore --scratch-path build/core
zsh scripts/tests/mac-install-test.sh
zsh scripts/mac-install.sh --no-install
```

On the validation host, Xcode 26.3's package-plugin sandbox stalled during Foundation filesystem-service
lookup before executing the dependency plugin. Invocation-local `swift test --disable-sandbox` and
`xcodebuild -IDEPackageSupportDisableManifestSandbox=YES` let the pinned plugin run without changing
product dependencies or persistent preferences. The no-install script was run with an ignored PATH wrapper
that adds that Xcode flag. This is a host-specific validation condition, not a production app sandbox change.

Core regressions include real WebKit standards-mode rendering, legacy/new-boundary HTML recovery,
shared cross-surface cache references, retained draft/pending-command originals, cleanup failure notification,
late-download rejection, descriptor version/digest invalidation, and shared runtime job coalescing.

Source push, local universal app build/signature verification, installation and live acceptance are separate
states. This release does not establish installation on Pete's MacBook, authenticated live app behavior,
Intel runtime execution, or physical iPhone testing. Pull GitHub main and build locally for laptop acceptance.
