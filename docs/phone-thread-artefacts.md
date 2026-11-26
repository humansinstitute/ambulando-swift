# iPhone/iPad thread artefacts

Source build 117 brings the thread artefact workspace to iPhone/iPad. Use the
header Artefacts icon beside Pin to browse, open, switch or remove attachments.
There is no bottom switch, including when attachments exist. The later approved
header-only refinement supersedes the original bottom navigation proposal.

Chat and all loaded editor trees remain mounted while switching modes or closing
and reopening a local tab. The current Doc, board and HTML editors provide
revision selection; historical content stays read-only and pinned. Discuss this
returns to Chat with a title/revision target chip. Removing that chip suppresses
hidden artefact context for the next message while still saving dirty open editors
before enqueue. Selecting an artefact again restores context capture.

The implementation shares the existing Mac state and authorised browser. The
`MacThreadArtefacts` names remain stable for existing Mac callers. Its Mac split
layout and default save behavior are unchanged. The iPhone host is keyed by the
complete connection/workspace/channel/thread and identity boundary; a new boundary
gets new state. Shared membership is refreshed through the existing sync/store
and on reopen/foreground, with no view-owned polling.

Membership uses the existing `ambulando_thread_artefacts` v1 format and generic
thread metadata row-version CAS. It contains native Doc/File identities only;
revision pins, local views and drafts do not move other users' editors. Existing
CAS reconciliation preserves unrelated metadata and concurrent additions and
avoids replaying uncertain writes over later remote operations. Source access is
checked independently. Remove from thread does not delete source records. Detached
Doc recovery retains the existing durable automatic-publishing hold; re-add does
not release it without an explicit acknowledged source Save.

Send refreshes membership, flushes and saves loaded attached editors, validates
exact revisions/digests and freezes schema-v1 `ambulando_artefact_context` through
the existing durable outbox. Editor interaction stays held until enqueue returns.
Human text and kind33358 signing remain unchanged. Frozen retries retain captured
metadata after later removal. Offline/save/conflict failures retain the draft.
The mobile board barrier refuses unreviewed overlapping merges until explicit
Save, and preserves the local recovery draft after denied publication.

## Validation and limits

Core membership/CAS, exact-context/outbox and board tests run on the host. The
production phone state branches can also be exercised on a Mac without a device:

```sh
swift test --package-path AmbulandoCore --scratch-path <owned-core-build> \
  --filter 'ThreadArtefactMembershipTests|ArtefactChatContextTests|BoardEditingTests|DocumentRecoveryTests'
python3 scripts/tests/phone-thread-artefacts.py <owned-core-build> <owned-test-output>
```

The harness checks lazy membership, duplicate focus, hidden exact context, enqueue
hold, chip exclusion, failed save, detached recovery, re-add and close checkpoint.
It does not render iPhone UI. Installed SDK parsing/typechecking also does not
establish an eligible Xcode destination, linked app, UI, TestFlight or device test.

Whole-thread dismissal or process exit currently remounts editor views. Shared
attachments and durable drafts survive; exact local HTML/Doc revision pins and
editor viewports across that boundary are not implemented by the existing shared
Mac owner. This remains an explicit parity/acceptance gap. Tab close/reopen and
Chat/Artefacts switching within the mounted thread retain their trees. No claim
of complete close/relaunch viewport restoration or physical-device acceptance is
made. Mac source build remains 138.
