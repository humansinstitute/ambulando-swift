# Native workspace administration

Manage Workspace is shared SwiftUI, reachable from the actual sidebar workspace menu and Settings.
Mac uses section/detail navigation; iPhone uses pushed native forms. The workspace identity remains visible.
Connection/retry/diagnostics, appearance, optional sections and notifications remain in device Settings.

This action inventory was audited against `../sol/src/api.js`, `channels-manager.js`, `workspace-manager.js`,
`scopes-manager.js`, `scope-access-manager.js`, `wapp-management-manager.js`, `wapp-publishing-manager.js` and the
web's `docs/design/manage-workspace.md`. Tower is the authority; a visible record is never a grant.
All administration requests are confirmed online writes, never an offline/background admin queue.

`W` means `/api/v4/flightdeck-pg/workspaces/:workspaceId`. Every request uses current-user NIP-98 signatures.
No owner impersonation, server authority changes, private-key discovery, cache purge or cursor reset is introduced.

| Action | Authority | Web destination | Native destination | API / offline / evidence |
| --- | --- | --- | --- | --- |
| Workspace name, slug, description, avatar URL | workspace.manage / owner/admin | Workspace | Workspace / Edit | PATCH W; confirmed result updates only its persisted workspace, including shell name; profile isolation test |
| Public avatar file | same, rechecked before upload | Workspace | Workspace / Choose avatar | Global storage prepare/upload/complete; explicit public consent; metadata-stripped PNG; ordinary private attachment contract unchanged |
| Delete workspace | same; server protected-workspace/owner safeguards | Workspace | Workspace / Delete | DELETE W with confirmation workspace id; typed name and destructive confirmation; never tested against a real workspace |
| Create/edit/archive scope | scope.create / exact scope.manage and can_manage | Scopes | Scopes & Channels / scope settings | POST/PATCH/DELETE scopes; existing ManagementTests and ManagementUITests |
| Product template and starting channels | scope.create and channel.create | Scope wizard | Scopes & Channels / New scope with starting channels | Existing POST scopes then POST channels; same product JSON template, title/directory substitution; staged progress, no atomic-success claim |
| Personal scope order | own membership | Scopes | Manage scopes / accessible move controls | GET/PUT me/scope-order, expected_row_version; existing conflict/core/UI tests |
| Create/edit/context/reorder/archive channel | exact channel.create / channel.manage | Scope/channel settings | Scopes & Channels and existing sidebar | Existing ScopeChannelManager; confirmed writes; existing core/UI tests |
| Add workspace member (human/agent) | workspace administration | Groups & Members | Members / Add | POST members: member_npub, role member, kind; no role promotion invented |
| Edit member display name | workspace administration; server rechecks | Groups & Members | Members / Edit display name | PATCH members/:actor/profile with display_name; online |
| Create group | workspace administration | Groups & Members | Groups / New group | POST groups: name, kind custom; signed synthetic flow test |
| Add/remove group member | workspace administration; protected-group safeguards on Tower | Groups & Members | Groups / member actions | POST group members / DELETE stable actor; signed synthetic flow test |
| Attach/detach child group | workspace administration; Tower cycle checks | Groups & Members | Groups / child groups | POST/DELETE child-groups; signed synthetic flow test |
| Channel grant create/change/remove | fresh channel.grants.manage or exact actor/effective-group grant, or admin | Channel permissions | Permissions / channel | POST/PUT/DELETE grants; explicit actor/group and view/contribute/manage; fresh authority rechecked; channel.manage alone is insufficient |
| Scope access grant/revoke | exact scope can_manage; delegated scope manager supported | Scope permissions | Permissions / scope | GET/PUT scope grants; canonical scope edit lease + expected_revision; stale revision never rebased; custom/inherited access preserved; lease/conflict tests |
| WApp delegation create/revoke | workspace administration; owner/step-up checks on Tower | Permissions | Apps & Integrations / Delegations | POST wapp-delegations / revoke; explicit app/channel/scope and future expiry; no wildcard defaults |
| Installation reconcile/revoke | admin or fresh matching active delegation; Tower exact filters/step-up | App Management | Apps & Integrations / Installations | POST reconcile/revoke; visible record alone does not enable a write; app-filtered grants require matching destination filters |
| Managed app activation | admin or explicit selected delegation, server exact filters | App Management | Apps & Integrations / Activate | User-consented HTTPS Autopilot catalog; POST Tower intent then signed Autopilot process; intent, installation and request ids persisted for recovery; no automatic re-create after claim failure |
| Publishing installation add/edit/destinations/origins | workspace administration; server owner/step-up | App Management | Apps & Integrations / Publishing | GET/PUT wapp-publishing-grants; multiple explicit destinations; replacement consequences shown; missing old destinations block silent omission |
| Publishing disable/revoke/rotate | same; server step-up preserved | App Management | Publishing row actions / public-key rotation | POST disable/revoke/rotate; no private key handling; rotation nonce/expiry follows web contract |
| Group rename/delete; general workspace member removal/promotion | unsupported by current PG web adapter | Groups & Members | No unsupported control | Legacy encrypted group APIs are not portable PG contracts; no false parity claim |
| Managed app uninstall/runtime teardown | intentionally owner-only, additional approval | App Management | No working uninstall button | Revocation removes authority; it is not proof of runtime teardown. Existing web uninstall is explanatory only |
| Personal appearance, optional sections, notifications | personal/device | Deck / Notifications | Settings | Existing native controls preserved; web-specific Deck layout and Web Push settings remain distinct |
| Tower/NStack connection, retry and diagnostics | device identity | Connection & Diagnostics | Settings / Connection, Sync, Diagnostics | Existing HTTPS connection flow retained; native FIPS and browser-specific transports remain unavailable |

## Persisted reads, writes and recovery

Directories use `TowerClient.list` pagination and are stored by connection/workspace/list. Read actor decoding and
coalesced `LiveQuery` snapshots keep heavy work off the main actor. Lists refresh on entry and every 30 seconds while
visible, and successful mutations refresh them on return. Scope/channel access lists are also persisted and reactive.
Snapshots are explicitly cached, never authority. A failed refresh retains cached records and displays the error;
controls requiring fresh resource authority are disabled after a refusal. `/me` refresh failures clear cached UI authority.
Malformed row fallbacks use a deterministic digest; invalid targets cannot become write paths.

Each administration form keeps a local draft per connection/workspace/action. A workspace switch reconstructs the
entire management navigation; a late response only updates the captured workspace. An unchanged acknowledged draft
cannot be resubmitted in the same reopened editor without an explicit edit. No network retry is scheduled for admin
creates. An interrupted response may have reached Tower: the form says to inspect current state before retrying.
Scope setup records its created scope, checks Tower's channel names before continuing, and requires an explicit
recovery check/selection after an uncertain create. Activation saves the exact intent before processing and retries
processing that same intent. Owner `step_up_required` responses stay refusals; no silent escalation occurs.

## Remaining limits

The native scope wizard supports Blank/Product and existing scope role/channel access editors, but does not yet
mirror the web wizard's custom initial-grant rows, every template option or editable template channel previews.
The web greeting and Workrooms feature-flag editor are not exposed. Personal WApp launcher
create/edit/reorder/delete remains a Toolbox parity gap; workspace administration never treats launcher ownership as
workspace authority. Self-service display-name editing for a non-admin remains separate from these admin controls.
The narrow delegation editor chooses one explicit app and destination per grant; it does not expose every optional
installation/origin filter combination available in the web form. Existing app/destination-filtered installation
management is accepted only when its explicit filters can be matched; Tower may still require owner approval.

These are explicit unresolved native gaps, not placeholders counted as parity. Android is deferred.
A source commit or fixture success does not establish authenticated live behaviour, physical-device installation,
Keychain validation, background execution, Intel execution or notarization. Exact build, test, runnable UI, installation
and live boundaries are reported on the implementation task and ignored run evidence.

## Reusable checks

```sh
swift test --package-path AmbulandoCore --scratch-path build/core
# Dedicated sample iPhone; same production feature code, no real Tower.
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme AmbulandoTest \
  -destination 'platform=iOS Simulator,id=<dedicated-test-simulator>' -derivedDataPath build/test-ios \
  -only-testing:AmbulandoUITests/WorkspaceAdministrationUITests \
  -only-testing:AmbulandoUITests/ManagementUITests test
# Mac sample app built through the documented Test scheme.
'build/test-mac/Build/Products/Test/Ambulando Test.app/Contents/MacOS/Ambulando Test' \
  -AmbulandoFixtureAdmin -AmbulandoFixtureReset -AmbulandoMacThreadRegression \
  -AmbulandoMacWorkspaceAdministrationCheck
```

Core contract tests cover exact request bodies/NIP-98 hashes, authority loss and server refusal, scope leases/revisions,
people/group flows, directory pagination/isolation, persisted profile updates and explicit Autopilot origins. Fixture
admin mode is opt-in with `-AmbulandoFixtureAdmin`; normal sample mode remains a non-admin for existing regressions.

## Group browser and quick membership editing

Manage Workspace sizes its Mac sheet around 1100 × 780 points, bounded by the display's visible area, and permits
resizing even when opened above Settings. Groups has a separate browser with names, kind and direct-person/nested-group
counts. A selected group has its own title, direct people and nested groups. iPhone pushes from the group list into
membership details and from a person into their identity/membership page. Removing a person from a group preserves
workspace membership; detaching a group does not delete it or invite its transitive members.

The inline People/Groups picker searches the current connection/workspace's persisted directory by name, type,
canonical actor/group ID or full npub. Search work is cancellable and runs away from the UI actor; keystrokes never
issue network searches. Saved directory updates refresh suggestions. Up/Down and Return/Tab select; touch/click also
selects, with input focus retained. Existing members and graph edges are labelled; self/cycle hints are disabled.
Tower remains authoritative for protected/system groups, current permission, and concurrent graph changes.

For an unknown valid full npub, the user chooses Person/Agent and confirms the public identity and destination once.
The client uses the additive atomic `POST W/groups/:groupId/members` body
`{member_npub, ensure_workspace_member: true, kind: "human" | "agent"}`. Tower must preserve an existing role and actor
kind, create only a member role when absent, and commit workspace enrolment and the group edge together. This contract
was coordinated with Tower because ordinary `POST W/members` is a role-replacing upsert and cannot safely implement a
race-free two-step enrolment. Native never falls back to that upsert. An older server's refusal retains the draft and
explains that safe enrolment may be unavailable. There is no automatic blind retry after an interrupted response;
an explicit subsequent attempt rechecks the group and uses the same idempotent edge. Successful writes and failed
readback have separate messages. No client-side role promotion or transitive enrolment is introduced.

Draft search/key, identity type and picker mode persist per connection/workspace/group. In-flight writes retain their
captured workspace, and further writes stop when the selected workspace changes. Administration remains online-only.
The local fixture and contract tests are distinct from actual backend activation and authenticated live verification.
