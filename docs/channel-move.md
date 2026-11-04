# Move a channel to another scope

On iPhone, iPad and Mac, open Channel settings and choose **Move to scope…**. Choose a
scope in the current workspace, then preview access changes. Tower decides whether the
source channel and destination can be managed and whether their kinds support moving.
Special, archived, default, DM and system channels/scopes may be refused with an explanation.
The picker is discovery, not proof of management permission.

The review distinguishes gained, lost and retained channel content permissions from scope
visibility/management. Tower's exact channel grants remain unchanged; scope grants alone do
not confer inherited channel content access. Names, permissions, direct grant count and
warnings are shown before **Confirm move**. Technical grant identifiers are not displayed.
Unknown additive response fields are tolerated; missing core access information prevents confirmation.

A preview binds the requester, channel/source revision, destination and access state. A stale
preview or permission refusal clears confirmation and requires a new preview. A response lost
after confirmation retains the exact token and mutation UUID for **Retry same confirmation**;
there is no automatic background replay or optimistic scope write. Closing an uncertain flow
leaves location to the next authoritative refresh; inspect location before starting a new move.

After Tower returns the canonical channel, SQLite updates the channel and loaded task,
document, file, view-state, agent-activity and pin locations in one transaction. Content IDs,
bodies, drafts, links and versions remain intact. Child projections from Tower can follow.
The workspace refresh gathers all visible channel lists before applying destination rows and
pruning old source lists. A source list cannot purge content simply because its destination
list happened to load later. A true access loss still removes inaccessible local content.
The normal channel event triggers this structure refresh; reconnect event replay and gap
recovery use the same path. The native client uses the existing event cursor protocol,
not Tower's optional record-device checkpoint protocol.

## Verification

`ChannelMoveTests` covers preview without an optimistic move, an interrupted confirmation
with identical token/mutation retry, 403/404/409 refusals, malformed previews, and canonical
relocation preserving loaded task content across source pruning and older channel projections.
Run alongside management, sync, live-sync and scoped query suites. Build both `Ambulando`
(iOS Simulator) and `AmbulandoMac` with the project scripts' package-plugin validation flag.

Release metadata: iPhone/iPad build 83; Mac build 74. Local builds and test doubles do not
prove authenticated live moves or installation on Pete's iPhone/MacBook.
