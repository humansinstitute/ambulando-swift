# Workspace Home links

Home, Goals, Reminders and Loops are peer links in each workspace sidebar. In stacked navigation each link first
activates its own workspace, checks that boundary again, and then opens its destination. The shared screens and
sidebar also compile for iPhone; separate device interaction validation remains necessary.

Home opens the existing personal Home screen. Goals opens a combined list of readable goals across every active
scope and channel of that workspace, using existing channel/File and generic relational Goals reads. Goal details
retain their original record identity, revisions and server permissions. New goals still use the existing personal
Goals setup. The combined list has separate model state and does not replace Home's personal list or its encrypted
snapshot. The combined list requires an online refresh after relaunch; it does not claim a complete offline listing.
Denied channels are omitted, unreadable goal content is disclosed, and network failures offer retry rather than a
successful empty list. Workspace switches and access invalidation fence in-flight results.

Reminders opens the existing personal Note to Self task board and reuses its actions and records. Loops is an
explicit placeholder describing regular work delegated to agents; it does not configure or imply a scheduler.
Goals and Loops use workspace-bound navigation routes, so goal detail can return to the combined list and section
navigation restores within the same workspace.

The chat `@` picker discovers synced native Files, including Excalidraw artefacts, with ordinary name lookup or the
`file:`, `artefact:` and `whiteboard:` prefixes. It refreshes every page of the active channel's Files before lookup.
`goal:` remains the personal goal-name picker. File suggestions insert `@[Title](mention:file:<record UUID>)`;
the body retains that record UUID through send and rendering, while only people/agents enter notification routing.
Opening follows the existing authenticated File route and its permissions. Archived, deleted and revoked Files and
records outside the current workspace are excluded from discovery.

Validation lives in `WorkspaceGoalsTests`, `FileMentionSyncTests`, the File cases of `MentionLookupTests`, and the
isolated Mac Test scenario `-AmbulandoMacWorkspaceLinksCheck` with `-AmbulandoFixtureGoals -AmbulandoFixtureDMs` and the normal
`-AmbulandoMacThreadRegression` entry point. These use synthetic Tower records and establish local behavior,
not installation or authenticated verification on another Mac.
