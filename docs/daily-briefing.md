# Rick’s personal Home briefing

Home reads an owner-private journal written by Rick. The Mac client never generates an entry, publishes a version,
changes a goal or task, or alters source-channel permissions. Rick’s scheduler and publication review remain separate
from client delivery. The existing 06:00 infographic is independent.

## Shared application format

Android owns the canonical v1 contract in its `docs/daily-briefing.md`. Swift consumes those same bytes:
`application/vnd.ambulando.briefing+json`, `schema: ambulando.briefing`, `schema_version: 1`, workspace/owner/author
identities, `timezone: Australia/Perth`, and `entries` keyed by canonical calendar date. Entries contain the RFC3339
`generated_at`, one/two plain-text `paragraphs`, required `links` and optional `coverage_note`. Thread references
require a channel ID. Bounds are 4 MiB, 3660 days, 4000 characters per paragraph, 20 links, 160 characters per label
and 1000 characters for a coverage note. Unknown fields can be read; the native client does not rewrite them.

The dedicated non-DM channel is discovered through `metadata.system_key = ambulando.briefings` and
`metadata.briefing` with schema version, owner and author. The File has the same briefing metadata. Neither the
channel name nor metadata establishes authority: current membership and complete direct grants must resolve to
exactly the owner and named author, with manage for the owner and contribute/manage for the author. Historical
member kind labels are not permission checks. Groups, extra principals, duplicate candidates, partial lists,
unverified identities and unreadable grants fail closed. No self-DM content is read, and Goals access is unchanged.

The sync service reads the current File metadata and fetches that exact immutable version. Size, SHA-256, MIME,
workspace/channel, metadata and body identities must agree before display. It does not enumerate a capped history
list to read the current journal. The publisher uses absent-date CAS insertion and readback; Swift has no writer.

## Display and recovery

Dates and the daily 05:30 boundary use Australia/Perth independently of the Mac’s timezone. Historical paragraphs
remain the saved analysis for that selected date; current goal facts are shown separately and cannot reconstruct
historical briefings. Today is the newest selectable day. Author, generation time and native record links retain
source context; opening a link grants no additional access.

Loading, no entry yet, unavailable, cached and stale states must be explicit. A previous day is never relabelled today.
A verified encrypted snapshot can support offline reading for its exact account/backend/workspace/application
boundary. It is not fresh server authorization. Lock/account/workspace changes must hide the old state; explicit
access loss or invalid source state removes the snapshot. Refresh failures are not successful empty journals.

## Verification boundary

Parser and transport fixtures use synthetic identities and records; passing them does not prove real publication.
A real Rick-written entry and authenticated immutable-version/current-journal readback are required before the
manager claims integration works. Mac delivery means validated source pushed to GitHub main; Pete pulls and builds
locally. Installation and use on Pete’s MacBook require separate evidence. iPhone and web parity are separate work.

The actual local Wingman Suite architecture v7 scene was inspected, including nested elements, geometry and arrow
bindings: generic shared records/ACL/storage belong to NStack, domain interpretation to Ambulando, and scheduled
generation to Autopilot. The manager’s hosted legacy-catalogue investigation could not establish a newer hosted
scene. This feature adds no NStack route, table, backend enum or parallel catalogue.
