# Start a private direct message

DMs → All channels → Deck Inbox **+** opens the recipient picker on Mac and iPhone.
The iPhone floating **+** does the same. The Chat toolbar and sidebar scope **+**
use the same picker, including sidebars with multiple enabled workspaces.
A stacked sidebar action activates its captured workspace before showing recipients.

Choose a person, agent or Note to self, then Create. The existing core manager reuses
an active DM only when its recorded participant npubs match exactly. Otherwise it
posts `kind: dm` and the exact participant npubs through the shared Tower scope-channel
route. No ordinary channel grants, groups or inferred recipients are added. Tower
remains the authority for membership and private access. The response must contain
exactly the requested participants before it is stored or opened.

Successful creation updates the local channel store immediately; dismissal opens
Chat in that channel's actual scope. Cancel leaves the context untouched. Create
stays disabled without a recipient. Empty directories explain the absence of choices;
directory errors offer Retry people. A creation refusal retains the picker and selection
with the existing management error. Workspace changes dismiss the picker, and the
result must still belong to the same workspace boundary before navigation.

A selected DM's Deck **+** still starts a new thread in that DM. Ordinary scope and
channel thread creation, and named-channel creation, keep their existing flows.

## Repeatable local checks

Use isolated sample apps, never a production account:

- `ManagementUITests/testDmDeckPlusCreatesReusesAndKeepsSelectedDmThreadAction`
- `ManagementUITests/testDmDeckEmptyDirectoryAndDirectoryFailureCanCancel`
- `ManagementUITests/testDmDeckCreationErrorKeepsRecipientAndAllowsCancel`
- `ManagementUITests/testStackedSidebarDmPlusActivatesItsWorkspaceBeforeCreation`
- `ManagementUITests/testNewDirectMessageFromToolbarAndSidebarReusesTheConversation`
- `ManagementUITests/testCreateRenamePromptMoveAndArchiveAChannelInAScopeYouManage`
- Core `ManagementTests` verifies the request contract, exact participant reuse,
  Note to self, rejection of identity inference and ordinary channel creation.

The Mac Test app accepts `-AmbulandoMacThreadRegression -AmbulandoMacDMCheck
-AmbulandoFixtureDMs -AmbulandoFixtureReset`. Add one of
`-AmbulandoFixtureDMDirectoryEmpty`, `-AmbulandoFixtureDMDirectoryFail` or
`-AmbulandoFixtureDMCreateFail` for empty/error/cancel checks. The main DM check also
creates a named ordinary channel through the stacked sidebar plus and verifies its
stored kind, scope and Chat navigation.

These checks use the in-process sample Tower. They do not establish authenticated
Tower behavior or installation on a physical device. See [test apps](test-apps.md)
for building and launching isolated apps. Keep run logs/screenshots in ignored
`tmp/docs/handoffs/`, not in reusable documentation.
