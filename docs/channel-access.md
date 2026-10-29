# Channel access

Channel creation on iPhone, iPad and Mac supports explicit person/agent and group grants with View, Contribute or
Manage. The create request carries `grants` atomically with the channel; no follow-up sharing writes are queued.
An empty list leaves the creator alone. The creator is excluded from recipient choices and a fresh `/me` read removes
any explicit self bundle before creation, preserving Tower's creator recovery bundle. No other audience is inferred.

Channel settings opens the same access editor used by Manage Workspace. Tower's `person` response alias maps to
`actor` in native requests, and nested recipient metadata supplies names. Standard editors start at the current level.
Unknown custom bundles show their concrete permissions and remain protected from preset replacement; an authorized
manager may add a separate grant or explicitly confirm revocation. Scope roles are listed separately: they authorize
scope/context work, never linked content or channel participation. Direct channel managers do not need the admin-only
group-list endpoint to change a grant. Group-derived authority uses known effective membership; workspace-wide `/me`
channel permission unions alone never prove authority on the selected channel. Tower checks every request again.

People choices use the member directory; groups use existing scope management choices or workspace administration.
If Tower denies these group directories, native offers individuals and explains the unavailable group choices.
Recipient refresh retains the channel draft. Administration is online only; refusals retain drafts and do not queue
sharing mutations. Connection/workspace guards prevent late lookup responses from filling a different workspace.

Scope/channel lists remain in SQLite and SwiftUI observes them. Channel-list jobs now use the bounded transient read
retry policy and inherit explicit refresh force from discovery/workspace refresh. Successful complete lists remove
revoked channels and content using the existing store purge; failures do not fabricate grants or an empty success.
The sidebar uses Tower's readable-channel lists without an additional membership filter. A reported device visibility
mismatch still needs device/identity/cache evidence; these corrections do not establish its exact historical cause.

Validation: `swift test --package-path AmbulandoCore`, focused workspace administration and workspace-sync tests, and
Xcode Mac/iOS Simulator builds. Core tests cover atomic create payloads, creator recovery, person aliases/names, direct
manager operation without admin group access, denied unrelated-channel permission unions, force-refresh revocation,
transient read retry, and channel/grant/group/member events discovering newly eligible channels and removing revoked ones.
Sample UI/transport checks use synthetic data and cannot establish a real account's authority. Installation, shipped
builds, real-device behavior and cross-client authenticated checks must be recorded separately on the release task.
