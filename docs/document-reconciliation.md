# Preserved document drafts and remote review

Mac build 55 and iPhone/iPad build 64 keep an open document's working copy when a newer shared save arrives. The latest successful server save remains the shared document. Native never treats a newer download as permission to replace local text, title, or an unfinished merge.

## Reviewing a newer version

The editor checks on foreground return, reconnection, materialised document updates, its active minute check, and before Save. A persistent **Newer version available — Review changes** action shows a line diff of the local working copy and latest shared version, with the local base and remote version numbers. Full copies remain available for reading and copying. The layout scrolls on iPhone and uses the available Mac sheet width.

**Keep editing** closes review without changing the working copy or clearing the notice. **Accept latest** explicitly confirms replacement, saves the original in **Preserved drafts (on this device)**, and fetches the reviewed head again before replacing the page. It does not acquire a lease, submit a body, or create a shared version. If the head changed again, acceptance stops for another review. Preserved copies can be previewed, copied or restored as a local draft; they are not newly published versions.

## Common-base merge

The local review journal retains the exact common saved body, title, row version, hash and storage identity independently of the mutable remote cache. A restored older draft only uses that base when the complete identity matches and the retained bytes verify. Upgraded drafts whose bases are missing offer manual comparison and copying; automatic merge stays disabled. A changed or unsupported stored format also requires manual review.

**Merge my changes** combines independent edits using the retained base. Markdown merges preserve whitespace and deletions. Rich merges operate on authoritative document nodes, text, marks, attributes and unknown envelope fields; generated Markdown/block fields are regenerated from the resulting rich state. Ambiguous overlaps require explicit **Use local** or **Use latest** choices. Large or ambiguous changes can conservatively require resolution rather than guessing. Conflict messages show passages or formatting descriptions, not internal JSON paths.

The resolved preview can be reviewed before **Edit merged result** prepares a durable local draft. Rich content opens in the normal formatted document editor; Markdown also has a text preview. Preparing a merged draft does not publish it. Autosave and background flush leave that draft local until the person explicitly chooses **Save**. Save keeps the existing server permission, lease, expected row version and body-hash checks. A v6 draft merged with v8 saves as v9 only if v8 is still latest and no authority barrier intervened. Tower assigns the version number.

A remote change while review is open updates the comparison target without replacing the original draft or edited preview. Applying a preview re-fetches its reviewed head. A mismatch requires **Reconcile preview with latest**, using the previous reviewed head as the next common base; original and earlier preview copies remain recoverable. Partial conflict choices and preview edits are persisted. Invalid/incomplete preview source is retained too. Cancellation, offline errors, backgrounding and an expired lease do not retire the draft. A failed save response can retry: if the server already holds exactly the submitted body hash and title, native acknowledges it without another body mutation.

## Server compatibility and permissions

Native first inspects document editing capabilities. It selects `document_concurrent_edit_v1` only when `document_edit_protocols` advertises that exact marker, then requires the selected protocol and matching editor session in acquire and renew responses. It sends the existing `lease_token`, `row_version`, and `base_body_sha256_hex` body contract. A failed concurrent acquire never silently downgrades or takes over another editor. Humans and bots use the same server authorization and version checks.

A server without the new advertised capability keeps `document_edit_session_v1` behavior. Older servers without the inspection route retain ordinary exclusive acquisition. They cannot provide independent concurrent publishing: another active exclusive editor blocks acquisition. Explicit legacy takeover remains available where supported, preserves divergent work through the existing Tower recovery path, fences the previous token, and creates Tower's authority-barrier version. These controls and their one-editor explanation are hidden in concurrent mode. A changed legacy observed lease, unsupported takeover protocol, denial or failed recovery never becomes permission to force a save.

Deleted or inaccessible documents report the error and retain local work. Local recovery does not confer access or bypass a subsequent server check. Native source does not activate a backend protocol. Serving Tower capability, installed app versions and authenticated multi-editor acceptance must be verified separately. Android remains deferred.

## Validation

Core checks cover independent and overlapping changes, deletion, marks, unknown fields, invalid bases/formats, preview rebasing, durable journal retention, preflight, uncertain-response retries, save races, protocol negotiation, strict echoes and no downgrade. Run:

```sh
swift test --package-path AmbulandoCore --scratch-path build/core
```

The existing isolated Mac harness includes a shared native editor-model reconciliation check against synthetic Tower data and SQLite. It exercises v6 versus v8, accept without a version, merged v9, edited-preview reopen, a review/save race, explicit overlap choices, background preservation, rich editing, offline failure and duplicate-free retry. Build `AmbulandoMacTest` and run its executable directly without installing:

```sh
'build/review-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoFixtureReset -AmbulandoMacThreadRegression \
  -AmbulandoMacCommentMentionCheck -AmbulandoDocumentReconciliationCheck
```

The full document workflow retains its native comment/layout checks and now expects explicit acceptance rather than automatic page replacement. Simulator compilation and fixture checks do not establish physical iPhone/iPad testing, installation on another Mac, or authenticated live Tower behavior. Operational evidence belongs on the task or in ignored `tmp/docs/handoffs/`.
