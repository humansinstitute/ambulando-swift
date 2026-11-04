# Live agent activity (iPhone, iPad and Mac)

Shared `AmbulandoCore` and `Ambulando/Views` code shows, for every conversation, whether an agent is working on it now
and the public commentary it publishes while it works. Tower is the only source: the app never connects to Autopilot or
any agent host. Design: "Tower-backed live agent activity" (Flight Deck document 60ed156f, §10–§11); Tower contract:
`tower/docs/design/agent_activity_turn_contract.md` (lease v2).

## What is shown

The open conversation ends with one card per current agent turn (`ThreadActivityStrip`, inside the message stack so the
composer and list keep their height):

| Turn | Header | Lines |
|---|---|---|
| working, lease live | spinner, "Working…" | newest 3 public lines, "show all" up to 20 |
| working, no new line for 5 min | "Still working · no update for N min" | same |
| waiting (suspended on a human) | "Waiting for you" | same |
| queued | "Queued · position N" | — |
| lease deadline + 15 s passed, not terminal | "Stopped responding · last update hh:mm" for 10 min, then hidden | collapsed |
| completed / failed / cancelled | "Earlier activity · completed" (newest finished turn only, if it said anything) | collapsed |

Durable final replies are ordinary messages and are never hidden or replaced. New lines are followed like new messages:
only when the reader is already at the newest message. Drafts are untouched.

Deck's "Agent working" label and the Agents screen use the same rule: live means not terminal, no `expired_at`, and
Tower's current time before `lease_expires_at` + 15 s. A non-terminal turn whose lease passed is "Stopped responding",
never finished. Stored `lease_health` is ignored (Tower computes it when serializing, so an event's copy is always
`live`).

## Clock

`ServerClock` keeps one estimate of Tower's clock per Tower origin: the top-level `server_time` of `GET agent-activities`
and of the SSE `connected` frame, else the HTTP `Date` header of those responses (one-second resolution, midpoint of the
round trip). Samples are anchored to `CLOCK_MONOTONIC`, which on Darwin keeps counting while the device sleeps, so a
device clock change never moves a deadline. Replayed event timestamps are never used. The last offset is stored per
origin only to evaluate rows on a cold launch before the first response.

Screens re-evaluate on every render: every 5 s while a turn is live, exactly at the next deadline + grace, and when the
scene becomes active (so a turn that died while the app was suspended does not show as working after foreground).
Foregrounding an open conversation refetches its activity, which also recalibrates the clock.

## Sync

- Stream and poll events (`entity_type: agent_activity`) carry the full serialized lifecycle in
  `payload.agent_activity`; it is merged directly (no refetch), including its `commentary_history` delta. Every v1
  heartbeat and every v2 lease event (`lease_event: renewed | resumed | expired`, same envelope) therefore delivers its
  deadline. An event without a usable row falls back to the old channel refetch.
- Merge per lifecycle row (`AgentLiveness.merge`), order-independent: state and text by higher `sequence`; lease by higher
  `(lease_epoch, lease_sequence)` (v1 rows without them keep the higher-sequence copy's lease); an `expired_at` survives
  other copies of its epoch and a higher epoch clears it; terminal always wins; a different `turn_id` is refused.
- Opening a conversation reads `GET agent-activities?channel_id&thread_id&history_limit=20&limit=10`. A lifecycle seen
  for the first time is seeded with Tower's high-water `commentary_cursor`; one seen before is recovered with
  `activity_id&after_commentary_cursor=<saved>` pages (≤ 5 × 20), advancing the saved cursor only with what was stored.
- Channel pages (Deck, Agents) stay `history_limit=0`. A page removes a stored lifecycle only when it proves it gone:
  inside the page's window and created at least 5 s before Tower answered, so a turn that started while the page was in
  flight is never lost.
- Storage (schema v9): lifecycles in `agent_activities` (newest 50 per channel) and immutable commentary in
  `agent_activity_commentary` (newest 50 per lifecycle). A 403/404 on a channel, a lost channel and workspace removal
  delete both.

## Limits

- "Working · reconnecting…" (transport lost while the lease is still live) is not shown separately: the card keeps
  "Working…" until the deadline passes.
- v1 producers can still revive a dead turn with a late durable replay (Tower legacy limit); v2 producers cannot.
- Android follows later; web is a separate client.
- Sample-data evidence: `-AmbulandoFixtureAgentActivity` (Rick publishes five lines with a 20 s lease, replies and
  completes) and `-AmbulandoFixtureAgentActivityStall` (stops after three lines), driven through the fixture event
  stream (`AgentActivityUITests`).
