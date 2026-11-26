# Goals (Mac source build 138)

A personal goal has a name, a description, optional date-only start and target dates, an ordered timeline of
checkpoints and links to existing chats, tasks, documents and files. Progress is "checkpoints reached"; nothing is
inferred from linked tasks and nothing is ever copied from a linked record. Completing a goal is explicit, and archiving
keeps every checkpoint and link. Android, Mac and agents read and write the same format.

## Where goals live (no new backend)

Goals use existing generic Tower contracts only. NStack gets no Goals endpoint or table; Ambulando owns the meaning.

- **One File per goal**, content type `application/vnd.ambulando.goal+json`, `metadata.goal.schema_version = 1`.
- **In the owner's private Goals channel**: a channel with `metadata.system_key = ambulando.goals` and
  `metadata.goals.owner_npub = <owner>`. Tower authorizes a channel only through grants on that channel, so a channel
  created for the owner is private to the owner plus agents they explicitly grant. It is *not* the owner's self-DM
  (agents cannot read a self-DM) and it is not a shared Doc.
- **The client does not trust the label.** Before every use the app reads the channel's grants and refuses it
  (`unsafe`) if a group, another person or an unknown principal holds access, or if the owner holds none. A channel
  someone shared with the owner and dressed up as a Goals space is never written to.
- **Revisions**: every save is a new immutable File version posted with `base_version_id`; a lost race answers 409
  `stale_base_version`. History, sync and recovery are the File contract's.
- **Typed, expectation-checked edits**: an edit carries the value it expects to replace. A save that loses the race is
  re-applied to the new head, so independent changes from two devices or an agent both survive; an edit whose expectation
  no longer holds stops with a readable conflict and saves nothing. An edit already in effect is accepted.
- Unknown top-level, checkpoint and link fields are preserved. A known field of the wrong type is refused (the goal is
  shown as "could not be opened"), never read as empty, so a rewrite can't erase checkpoints or links. A newer
  `schema_version` is left exactly as stored.

### Format `ambulando.goal` v1

```json
{"schema":"ambulando.goal","schema_version":1,"name":"…","description":"…","start_date":"2026-12-01","target_date":"2026-12-18",
 "status":"active","checkpoints":[{"id":"cp-1","title":"…","date":"2026-12-10","description":"…","reached":false}],
 "links":[{"type":"task","record_id":"<uuid>","channel_id":"<uuid>"}]}
```

`status` is `active|completed|archived`; link `type` is `chat|task|doc|file` (a chat link's `record_id` is the thread id).
Dates are `yyyy-MM-dd`, validated, target not before start. Limits (UTF-16 units, as Android counts): name 120,
description 2000, checkpoint title 120 / description 500, 100 checkpoints, 500 links, 256 KiB. Shared fixtures:
`docs/fixtures/goals/android-written-v1.json` (Android shape with unknown fields) and `agent-written-v1.json`
(canonical bytes the agent tool writes); both are read by the Swift and JS tests.

### Focus order (`focus_rank`)

Home shows goals in *focus order*, and the owner reorders them to choose which three are in focus. The order is part of
each goal, not a separate catalogue: no new record type, endpoint or backend change.

- **Field**: optional top-level `focus_rank`, a string of 1–64 characters from
  `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz` (ASCII order) that does not end in `0`. It is a
  fractional index: keys compare by code unit, and a key exists strictly between any two distinct keys.
- **Placement**: it is carried in the unknown-field area, so a client that predates it (Android 88, Mac 136, older agent
  tools) preserves it byte for byte, and new clients write it in the same position (in place when present, otherwise
  after the other unknown top-level fields).
- **Invalid values** (wrong type, other characters, trailing `0`, longer than 64) read as *unranked* and are kept untouched
  until a valid rank replaces them. They never make a goal unreadable.
- **Comparator** (the same on every client and in `goals.mjs list`): status (active, completed, archived); then ranked
  goals by `focus_rank`, before unranked goals; unranked goals by `target_date` (none last), then `name` with only A–Z
  folded to lower case; finally the File id. Every comparison is by UTF-16 code unit. Equal ranks are ordered by File id.
- **Keys**: `keyBetween(a, b)` is the midpoint of David Greenspan's "Implementing Fractional Indexing" (the MIT
  `fractional-indexing` package) without its integer header. Midpoint digit is `floor((a + b + 1) / 2)`.
- **Moving** a goal within one status group (`planMove`) writes, top first:
  - usually one goal: a key between its new neighbours;
  - when it is placed below an unranked goal, the unranked goals above it first, each after the previous key, in their
    current order (ranked goals always sort before unranked ones). New goals are not ranked when created.
  - **Rebalance**: if the neighbours' keys are equal (two devices picked the same key) or the new key would exceed 64
    characters, every goal from the top through the last ranked goal (or the moved goal) gets evenly spaced short keys,
    writing only those that change. Keys only grow when many moves land in the same gap, so this is rare.
- **Conflicts**: each write is the ordinary expectation-checked edit `set_focus_rank` (`expected` = the valid rank the
  mover saw, or `null`; `value` = the new key, or `null` to clear), saved with the existing File compare-and-swap loop. An
  edit already in effect is accepted. If another device moved the same goal, the edit stops with "The goal order was
  changed elsewhere" and saves nothing; a deleted or inaccessible goal stops it the same way. The move stops at the first
  refused write: later writes are not attempted and the plan is never retried as a whole. Earlier writes stay (every
  intermediate state is a valid order); the client reloads and reports "Saved n of m order changes". Archived goals
  are not reordered.
- Shared fixture: `docs/fixtures/goals/focus-order-v1.json` (alphabet, valid/invalid values, keys, rebalance keys,
  comparator, move plans, canonical bytes, conflicts). Swift `GoalFocusTests`, JS `goals-lib.test.mjs` and Android
  `core/goals` tests assert the same values.

## Access

- The owner and the agents the owner chooses. Agents get `contribute` through explicit channel grants; the app's Goals
  screen lists only agents. Nothing is inherited from scope or workspace roles.
- Links are references. Opening a link goes through the source record's own access: a record the viewer cannot read shows
  as "Not available" and stays removable. Linking never copies content or widens anyone's access, and unlinking never
  touches the source. One record can be linked from many goals.
- Setup, if no Goals channel exists yet, is one screen: where to keep goals (Home is suggested when exactly one scope has
  that name) and which agents may add to them. Tower decides whether this identity may create the channel; a refusal is
  shown as such. The app never reaches for a self-DM.

## Mac

- **Home → Goals** in the sidebar (row under Home) opens the list on Deck; Deck also has a Goals card of active goals.
- **Home** (globe, or Home in the sidebar) shows goals in focus order: three full cards, the fourth quieter, then "Show all
  goals"; drag, a card's menu or its accessibility actions reorder (see Focus order). Beside them, Daily Briefing restates
  saved dates and checkpoints only ("Agent briefings aren't available yet") and Latest shows the five most recent chats.
  The Deck section keeps the dashboard.
- **Goal form keys**: focus starts in Name; Return there moves to Description, where Return is a newline; Tab and
  Shift-Tab move between Name, Description and the two date controls; ⌘Return saves; Escape cancels. Date controls are
  always in the Tab order and changing one includes that date. The "include" checkboxes follow the macOS keyboard
  navigation setting: with Full Keyboard Access off they are reached by pointer, so clearing a date from the keyboard
  alone needs that setting on.
- The list groups Active / Completed / Archived, shows progress and target date, and refreshes every 30 s while open
  (agents edit too).
- A goal shows name, description, dates, the timeline (click the dot to mark reached/unreached; menu to edit, reorder,
  remove; "Next" marks the first unreached checkpoint of an active goal) and Associated work grouped as Chats, Tasks,
  Artefacts. Edit goal changes name/description/dates; ⋯ completes, reopens, archives or restores.
- **Add to goal** (target icon beside the pin) on tasks, documents, files and conversations toggles membership of any
  non-archived goal. "Add work" inside a goal links tasks, documents and files from the synced records (chats are linked
  from the conversation).
- Code: `AmbulandoCore/Goals/*` (model, edits, Files API, space, links, service), `Ambulando/App/GoalsModel.swift`,
  `Ambulando/Views/Goals*.swift`, `GoalDetailView.swift`, `AddToGoalMenu.swift`. Tests: `GoalsTests.swift`.

## Agents

`scripts/goals.mjs` signs through the Autopilot capability broker (no keys; same pattern as `sol/scripts/artefact.mjs`)
and imports `sol`'s Tower client (`AMBULANDO_SOL`, default `~/code/ambulando/sol`). `--owner` is the goal owner's npub;
the signer may be a different identity (an agent) that holds a grant on the owner's channel.

```sh
export WINGMAN_TOWER_URL=<nstack origin>
bun scripts/goals.mjs space  --workspace W --owner <npub>                 # find + verify the owner's Goals channel
bun scripts/goals.mjs setup  --workspace W --owner <npub> --scope S       # only when none exists; owner manage, caller manage
bun scripts/goals.mjs list   --workspace W --channel C
bun scripts/goals.mjs show   --workspace W --file F
bun scripts/goals.mjs create --workspace W --channel C --name … --description … [--start d] [--target d]
bun scripts/goals.mjs edit   --workspace W --file F --ops '[{"op":"set_reached","id":"cp-1","expected":false,"reached":true}]'
```

Ops (each states what it expects to replace): `set_name`, `set_description`, `set_start_date`, `set_target_date`
(`expected`,`value`); `set_status` (`expected`,`value`); `add_checkpoint` (`checkpoint{id?,title,date?,description?}`,`after?`);
`update_checkpoint` (`id`,`expected{title,date,description}`,`value{…}`); `set_reached` (`id`,`expected`,`reached`);
`remove_checkpoint`; `move_checkpoint` (`id`,`to_index`); `link` / `unlink` (`type`,`record_id`,`channel_id?`);
`set_focus_rank` (`expected`,`value`). `list` returns goals in focus order with their `focus_rank`;
`move --workspace W --channel C --file F --to N` moves an active goal to position N (0 = top) with the fewest rank edits.
Before saving, every *newly* linked target is read from its own typed route (`threads`, `tasks`, `docs`, `files`) as the
signing identity: it must be readable, not deleted or archived, in this workspace, and its authoritative channel must
equal a supplied `channel_id`. A denied, missing, foreign or mismatched target refuses the whole edit (exit 1) with one
generic message that carries nothing from the record; nothing is uploaded. Links already on the goal are not re-checked,
and `unlink` never needs source access. A soft-deleted goal file (`deleted_at` set while `record_state` is still
`active`) is not a goal on any client.
Exit 3 means a conflict (expectation no longer holds, or the goal is archived): re-read with `show`, decide, retry.
Read the goal first and send what you saw as `expected`; never copy a version id to force a write.
To hand a goal to a person, mention or link its File (the goal's `file_id`): Mac opens a goal File as the goal view, not
its JSON, through the reader's own access; a deleted goal or one the reader cannot open never opens as a goal.

## Verification (Mac source build 138)

- `swift test --filter Goal` (AmbulandoCore): 39 tests pass, including the shared focus-order fixture (keys, rebalance,
  comparator, 15 move plans, canonical bytes), move saving that stops at the first refused write (stale rank, deleted
  goal), and the Daily Briefing facts. `bun test scripts/tests`: 23 pass (same fixture). Full AmbulandoCore suite: only
  the three known `duplicate column name: artefact_context` migration failures, unchanged from HEAD.
- Native check on the isolated Test app with the sample Goals space (`-AmbulandoFixtureGoals`, `SampleGoalsTower`):
  `-AmbulandoFixtureReset -AmbulandoFixtureGoals -AmbulandoMacThreadRegression -AmbulandoMacGoalsHomeCheck`
  (add `-AmbulandoMacGoalsFormOnly` for the form alone, `-AmbulandoMacGoalsHomeReadyOnly` for first-launch Home loading).
  It drives real AppKit key events and checks: Home shows goals on first launch without leaving it; focus order, three in
  focus plus a peek and "Show all"; narrow layout; a reorder writes one goal; Deck stays the dashboard; a goal opens its
  detail; a file mention of a goal opens the goal, a deleted or unreadable one does not; form focus, Return, Tab order
  with dates unset and set (each native date field takes Tab through its own parts), keyboard-set dates, invalid dates,
  ⌘Return from the description and a date, Escape; the caret drawn (window pixels) and contrasting in light and dark
  (the app's own Appearance setting). `-AmbulandoMacNavigationStripCheck` passes with Home as its own surface.
- First-launch fix: a Goals refresh started by a view that was then rebuilt was cancelled, and the rebuilt view's refresh
  was skipped as busy, so Home stayed "Loading goals…". `GoalsModel.refresh` now runs one load not tied to the calling
  view and later callers join it; the per-workspace current check is unchanged.
- Not verified: the Mac app on Pete's MacBook against the live Goals channel, and iPhone/web (no change there).

## Verification (Mac source build 135; build 136 changes noted)

- `swift test --filter Goal` (AmbulandoCore): 29 tests, pass (build 136 adds the soft-delete wire test). Covers format, strict typing, UTF-16 limits, edits, the
  compare-and-swap loop against an in-memory File, the grants safety rule, Tower response shapes (including the live
  `current_version: null` File read), 409/403/503/hash-mismatch saves and a locked identity.
- `bun test scripts/tests`: 20 tests, pass: `goals-lib` (same fixtures, same canonical bytes as Swift) and `goals-ops` (link preflight against a fake Tower client).
- Live (agent tool as a broker identity holding a grant on an existing owner-private Goals channel): grants verify as
  owner + agent only; create, three checkpoints, two concurrent edits both kept, a stale base refused with 409
  `stale_base_version`, a contradicting edit exits 3 with nothing saved, complete → reopen → archive, and an edit on an
  archived goal refused. The temporary probe goal was archived and then removed by its operator.
- Not verified live: the Mac app itself against the live channel as the owner (needs Pete's identity on the MacBook), a
  negative test with an unauthorized member (unit-tested only), and iOS (the iOS SDK is not installed on this build Mac).

## Follow-ups

- Android: apply strict typed parsing (a wrong-typed `checkpoints`/`links` currently reads as empty and would be erased
  by the next save), and add a Home-level entry (it is reachable only through Toolbox).
- iPhone and web Goals (nightly parity job). Chat picker inside "Add work".
