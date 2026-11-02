# Kanban card status

Task boards name each state in the column heading. Their cards omit the repeated
status badge and retain the title, priority, channel, assignee and queued/failed
write indicators. List rows retain their status badge; task detail retains the
state menu. Moving a task still uses the existing state write and column grouping.

The iPhone, iPad and Mac compile the shared `TasksViews.swift` renderer. Only the
board passes `showsStatus: false` to `TaskRowView`. The web client already omits
status on ordinary Kanban cards. Its Summary column retains the computed parent
state because Summary itself does not identify a state. Android is deferred.

Verify the iPhone flow with the isolated `AmbulandoTest` scheme and
`WorkFlowUITests/testTaskCreateStateCommentAndEdit`. It checks card placement,
absence of repeated state, retained priority, detail state changes, movement to
Review and the list status display.

For Mac, build `AmbulandoMacTest` and run its executable with
`-AmbulandoMacThreadRegression -AmbulandoMacKanbanCheck`. The isolated fixture
renders the production card at 240 points in light/dark themes, verifies retained
column status/title/priority and the default list badge, and emits screenshots.
These fixtures do not establish physical-device installation or live Tower writes.

## Drag, selection and focus columns

Drag a card to any status column, including an empty column or a collapsed strip.
On iPhone hold the card, then move it; on Mac use the pointer. Dropping into the
same column leaves the task alone. The card menu remains an accessible alternative
for moving a task. Scrolling and opening a card still use the normal board paths.
This release changes status between columns; it does not add the web's optional
manual ordering within a column.

Use a card checkbox or **Select**, then choose several cards. Clicking a column's
count toggles its loaded, eligible cards. The selected-count menu offers **Select
visible**, **Clear selection**, archive (with confirmation), done, blocked, ready
and today. Done/archive clear assignment; blocked keeps it. Ready assigns the
agent chosen under **Default agent on this device** in the same menu. That choice
is local to the current account and workspace, as is the web's setting. Today
uses the web's UTC date convention. Cancel or Escape clears selection; changing
layout, workspace, account or scope/channel clears it as well. Mac's selected-count
menu supports Command–A for Select visible.

The column chevron toggles a 44-point vertical strip with its title, task count
and expand control. Collapse choices persist locally per connection, account and
workspace; they are independent of the web browser's preferences. Counts retain
all displayed tasks, and a collapsed column remains a drop target.

Known parent tasks and cards with outstanding writes cannot be selected or dragged.
Pending actions keep their existing queue indicators. Bulk actions queue one durable
change per card and report how many were queued, rather than claiming they have
already saved. Failed/conflicting/unfinished actions remain in the board's change
panel and task detail with Retry, Apply mine or Discard. A partial archive can
therefore still be recovered after its card leaves the board. Independent cards
continue when another is refused; a failed action blocks later changes to that
same card. Existing offline queue, identity boundary and Tower permission checks
remain authoritative. No new backend or lease contract is introduced.

State and assignment changes are separate existing Tower requests. A second-step
failure preserves the accepted status locally and retains the unfinished action.
Retries read current values and avoid repeating an already accepted state change.
Client checks detect changes to the relevant observed fields before writing and
scheduling preserves unrelated metadata. The existing Tower routes do not enforce
an atomic compare-and-set for these updates, so a change after that preflight can
still race; this release does not claim an atomic bulk transaction.

Focused checks: core `TaskBoardTests` and `WorkTests`; iPhone Test scheme
`WorkFlowUITests/testKanbanSelectionBulkAndCollapsedDropTargets` and the existing
`testTaskCreateStateCommentAndEdit`; Mac Test app flags
`-AmbulandoMacThreadRegression -AmbulandoMacKanbanCheck`. UI checks use isolated
sample data and do not establish live-account acceptance or physical installation.
