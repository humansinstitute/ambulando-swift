# Native comment mentions

Task comments and document comments/replies use the shared `ContentTextEntry` actor lookup on iPhone, iPad and
Mac (builds 42/31). The source of candidates is the current record's workspace directory in SQLite, observed with
`LiveQuery`, with the same `MentionRanking` and `MentionPicker` used by chat. The active chat channel is never used
to select identities. Tower remains responsible for current record-read permission checks on each mentioned actor;
a rejected write stays visible in the existing durable write status UI. The local directory is not an ACL oracle.

`CommentMentions` completes only the `@query` immediately before the current caret, inserts the picked `Mention.token`,
and preserves the remainder of the body. `ComposerTextView` reports optional caret changes for comment fields;
its existing `ComposerText.remap` places the caret after an external completion. Ordinary chat input keeps its existing
behavior. Other iOS content fields retain system text entry. Upload placeholders, attachment Markdown and explicit
paste keep the existing content upload host. Both native platforms persist comment drafts through the synthetic
content namespace, which never points to a chat target.

The canonical Markdown tag contains the full selected npub and `person` or `agent` type. The UI submit payload and
`WriteSender` derive matching structured identities from these canonical tokens with the existing mention parser.
Plain `@Name`, invalid npubs and record-reference tokens do not create actor entries. The sender derives entries again
from the durable body, so a removed or stale entry cannot route invisibly. Top-level `mentions` and `metadata.mentions`
travel with the complete body through the existing NIP-98 authenticated comment route, including retry reconciliation
by `metadata.client_record_id`. No new signing protocol or private-key fallback is introduced. The supporting Tower
comment canonicalizer preserves the explicit person/agent type and uses the resolved npub/actor ID plus existing ACLs.

Actor links in `RichBlocksView` now open a local-store identity details sheet. The exact token npub selects a current
workspace directory row; historical labels are not lookup keys. Missing members are unavailable, and opening a tag does
not dispatch an agent. Existing comments render through this same path without rewriting their data. Comment accessibility
uses a container rather than combining the entire row, keeping its links reachable.

Existing API limits are preserved: task comments can be created; document comments can be created/replied to and resolved
or reopened. Neither comment-body editing nor task-comment replies have a supported route in this change.

## Validation

Core coverage in `MentionLookupTests` and `WorkTests` checks UTF-16 caret mapping, a mid-paragraph `@ric`, complete suffix
and attachment preservation, canonical identity/type extraction, no plain-label routing, comment send/reply, NIP-98
headers, exact structured npub persistence, ambiguous response deduplication and store rehydration.

`CommentMentionUITests` exercises the actual task/document fields in the isolated iPhone Test app, picker touch,
continued typing, accepted rendering, draft relaunch and document replies. The Mac Test app's in-process harness uses
`-AmbulandoMacThreadRegression -AmbulandoMacCommentMentionCheck` to exercise the real Comments panel, mouse and Tab
selection, mid-paragraph caret, persisted body/metadata, tag activation, draft reopen and document replies.

These fixtures use the labelled in-process Tower stand-in and synthetic identities. They do not establish a live Tower
round trip, live agent execution, physical-device interaction or production Keychain behavior. Exact observed results
and installed build receipts belong to the implementation task.

## Comment author identity and photos (iPhone/iPad 49, Mac 38)

Comment rows resolve through the same `PeopleDirectory` and `PersonAvatar` as chat. The recorded creator's npub
selects the profile; when a create or status response carries only `created_by_actor_id`, that ID is matched to a
member of the comment's workspace. The current account, updater, mention targets and display labels never select
an author. Missing identity remains Unknown (or the recorded label), and missing or invalid photos keep initials.

The original raw comment record supplies the creator ID for existing cached rows without a schema migration.
A same-version joined list response can enrich a previously actor-only row; subsequent actor-only responses keep
an already stored sender. Member, agent and profile updates reload the comment display. Roots and replies share
the same renderer, including after reopening. Profile opt-out, credential-free image requests and image URL policy
are inherited unchanged from chat.

`CommentAuthorTests` checks actor-only roots/replies, normalized actor IDs, cached rehydration, equal-version list
enrichment, later actor-only updates and unresolved/updater-only fallbacks. The isolated native comment checks add
`-AmbulandoCommentAvatarCheck` to emulate actor-only create acknowledgements and expose the rendered avatar state
to UI automation in Debug only. iPhone `CommentMentionUITests` and the Mac comment harness check image rendering
and reopen; invalid image data retains initials. All these identities and image bytes are synthetic, with no live
Tower write, production account inspection or physical-device check.
