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
