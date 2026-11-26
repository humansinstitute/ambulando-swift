# Conversation inbox (Mac source build 131)

Chat shows one compact row per cached conversation in the selected workspace,
scope or channel, ordered by latest message activity. Direct messages and Note to
self use the existing channel/participant records and labels. Rows show the title,
channel/person, participants, reply count, latest excerpt and activity date.

Chat is visible when no navigation choice is saved. A saved Show Chat choice is
preserved, including false. Older builds did not separately record whether a saved
false was a default or an explicit choice; those values cannot safely be inferred.
Settings → Sections → Show Chat remains available.

All shows every cached accessible conversation. Unread uses the existing thread
view state and never invents unread when it is absent. Mine includes conversations
the signed-in person started or participated in. These filters combine with context
and search. Legacy channel posts without a thread ID remain separate rows and open
the existing channel reader at that post; no thread or backend catalogue is invented.

## Local query language

| Input | Meaning |
| --- | --- |
| `deployment checklist` | Both exact words in the same conversation, possibly in its title and different messages |
| `"deployment checklist"` | Adjacent words in one title or one message |
| `title:"deployment checklist"` | Adjacent words in the title |
| `body:"deployment checklist"` | Adjacent words in a message, including replies |
| `title:deployment checklist` | Deployment in the title, checklist anywhere in the conversation |

Curly double quotes are normalized. A field applies only to the next word or quoted
phrase; whitespace after the colon is accepted. Punctuation separates words. Raw
FTS operators are never executed. Unknown fields, empty phrases, unmatched quotes,
adjacent quoted/bare text and excessive queries produce an explanatory message.
SQL values are bound, and the controlled parser creates quoted FTS expressions.

SQLite schema 11 adds title entries alongside the existing message-body FTS5 index.
A backfill and transaction-local triggers cover title renames, message edits,
deletions, sync writes and cache removal. Each clause is matched independently and
intersected by conversation identity, so different messages can supply different
words. Effective branch membership retains canonical message ownership. Every
contributing record is checked against workspace/access/lifecycle boundaries.
Results carry a highlighted plain-text excerpt and the exact body-message identity.
Opening it selects the existing bounded message window containing that identity.

## Reading, creation and coverage

Inbox selection opens the shared thread reader inside Chat, keeping the application
navigation visible. Its header retains channel, title, participants, Back and the
existing pin/thread actions. Own messages sit to the right. The existing Markdown,
attachments, mentions, agent progress, reactions, editing, signed send, draft recovery
and earlier/newer pages remain shared with Deck. Closing returns to the inbox's
query, filter and reading position. Deck and existing explicit links keep their
focused thread presentation. Chat's New thread uses the existing destination chooser
and signed composer, then opens the accepted conversation inline.

Search is offline over the device cache. It reports cached message count and the
number of channel message histories downloaded. Download history uses the existing
scheduled, resumable channel catch-up with per-channel activity/errors. It requires
an unlocked reader and connection; downloaded history is not a freshness guarantee.
The existing thread-title listing is capped at 200 per channel. Older renamed titles
can initially be missing. An explicit Download history also refreshes each known
older thread through the existing individual metadata read, sequentially and with
cancellation and surfaced errors. Unknown catalogue-only threads remain outside
the cache; no full title coverage is claimed.

## Verification and remaining acceptance

Core regressions cover grammar, phrases, curly quotes, malformed input, split terms,
title/reply hits, migration backfill/triggers, updates/removal, access and workspace
boundaries, deduplication/order, Mine/Unread, inherited hits and older-message windows.
The isolated Mac Test app has `-AmbulandoMacConversationInboxCheck` for actual native
search entry, selected old-message rendering, draft/back navigation, destination
selection, signed creation and wide/narrow screenshots. Run after building
`AmbulandoMacTest` in Test configuration, together with
`-AmbulandoFixtureReset -AmbulandoMacThreadRegression`.

`-AmbulandoMacConversationRichStress` additionally repeats tables, quotes and code
throughout the history. Initial dense-page runs exceeded the two-second heartbeat.
The final inline-pane dense run also exceeded it (about 3.48 seconds). That
rendering/accessibility stress limitation is unresolved: opening a page containing
dozens of rich blocks can visibly pause. Passing mixed-content checks do not
establish that every rich conversation is responsive. The normal native flow passes
old-hit entry, draft/back navigation, narrow/wide Markdown, destination selection
and signed creation returning inline. A profile sampled SwiftUI layout/accessibility
focus traversal; switching away from a navigation push passed the normal fixture,
without establishing one definitive cause or fixing dense-page performance.

These are local synthetic checks, not real-account, hardware keyboard or MacBook
installation acceptance. Shared iOS compatibility is checked separately; the host's
missing Xcode platform/runtime blocks a full iOS app build. Web/iPhone parity remains
pending the approved nightly catch-up. Android remains the primary release surface;
Rick reviews cross-platform integration before the full feature is accepted.

## Existing-store loading recovery (build 131)

Build 130's effective-membership summary predicates scanned workspace messages
repeatedly. Chat could occupy the serialized reader long enough to prevent Deck's
activity request from completing. Build 131 resolves canonical and inherited message
IDs with existing indexes before reading summary fields and participants. It keeps
record identities, branch membership, search semantics and schema version 11.

`ConversationLoadingRecoveryTests` reopens a schema10-shaped retained cache with
1,200 discussions and 48,000 messages, checks a deterministic SQLite work budget,
and queues the actual Deck request behind an in-flight Chat load. It also checks
branch deduplication, canonical ownership, title-index upgrade/idempotency and
retained drafts/outbox. The test fails against build130's query sources and passes
with the indexed reads. Run it with:

```sh
swift test --package-path AmbulandoCore --filter ConversationLoadingRecoveryTests
```

This establishes recovery on representative retained history, not acceptance on a
particular installed account. MacBook acceptance and the separate dense Markdown
rendering limitation remain pending. Nightly parity should wait for that review.
