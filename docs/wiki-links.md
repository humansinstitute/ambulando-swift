# Wiki links (iPhone, iPad and Mac)

How the native app opens, creates, picks, moves and lists links between documents. This is the native side of one
workspace-wide contract shared with the web client (Sol); Android is not covered yet.

## The contract the app keeps

- A link is the canonical `[Title](wiki:<document-id>)` in Markdown and an `fdWikiLink` node `{documentId, title}` in a rich
  document. The id is the identity. Scope and channel are where the page lives now, never part of the link.
- `[[Title]]` is a title-only reference: unresolved until one page is chosen or created. Inside code (inline, fenced,
  indented, or an escaped `\[[`) it is plain text everywhere: the reader, the editor page, search and binding.
- A link grants no access. The page opens only for someone Tower lets read it; a bound id that is not among the readable saved
  pages is shown and opened by id (so Tower decides) and is **never replaced** by a title match or a new page.
- "Note to self" is an ordinary private direct-message channel holding ordinary documents. There is no separate note record;
  the app calls a page in that channel a "note" in wording only.
- Nothing is rewritten by opening a document. Literal `[[Title]]` text, old Markdown and rich bodies stay as stored until
  someone links, creates or chooses.

## What happens

| Action | Result |
| --- | --- |
| Tap or click a bound link | Opens that page by id at once from the saved copy (refreshes behind it), under its current title. The source's unsaved text is stored as a draft first; if that cannot be stored the other page is not opened. Back returns to the source with the draft. |
| Tap a title-only link that matches exactly one page in the source channel | The match is bound (a stable link) and opened. |
| Tap a title-only link that several pages share | "Choose a page" lists each with Scope / channel; nothing is picked. |
| Tap a title-only link with no page | "Create page": pick the destination (default the source channel), then **Create and link**. |
| Type `[[` in the editor | A results panel over the page, this channel first, "Search every channel and scope" on request, "Create “q” or search more…". |
| Toolbar **Link to doc or note** | Sheet: search (this channel by default; every scope on request; same-titled pages listed separately), results labelled Scope / channel, and **Create and link** with type wording and destination. |
| Document actions › **Move…** | Destination picker, a plain statement of what changes (access follows the destination; links keep working only for people who can read it there; leaving or entering a private conversation needs an explicit acknowledgement), then a confirmed, online-only move. |
| Linked from | Pages whose saved text links here, including other channels and scopes, with a count of how many pages could be checked on this device. |

## Create and link

One durable write (`doc.create`) carries the link to put into the source (`wiki_source_doc`, title, occurrence, the number of
same-title references when it was asked for). It is idempotent: the page's upload is reused after a lost answer, a retry finds the
page already created, and a queued request for the same title and channel is never repeated. Before the write is retired the
source is updated: an open editor receives the link and makes it a durable draft; otherwise the draft-first save path stores it
(and saves it when the source had no unsaved edits of its own). If that cannot happen the write **stays queued** with the page's
location (`wiki_created_doc`), and the document screen lists it with Open the created page / Stop waiting. If the source's
same-title references changed after the request, nothing is bound by position and the person is told. The page opens for the
person only if they are still on the same visit to the screen that asked, with the same connection, account and workspace.
Leaving and returning starts a new visit; a delayed checkpoint or creation cannot take over that visit.

A durable draft is local recovery, not a canonical Tower save: the normal Save action still publishes unsaved edits. Every
editor binding outcome checkpoints dirty text, including a retry whose link is already in memory. A failed checkpoint keeps
the creation pending. Offline creation also stays pending until connectivity and source-link recovery succeed; retries reuse
the created page rather than making another.

## Move

`POST /docs/:id/move` with `destination_channel_id`, `destination_scope_id` and the current `row_version`; the same operation as
`wingman flightdeck doc move`. Online only, never queued. A 5xx or lost answer is reconciled by reading the document back
(moved, still in place, or **unknown**; "unchanged" is only claimed when Tower says so). A draft based on the moved version has
its base moved with it by a compare-and-set; a draft on an older version, or one being saved, stops the move first.

## Limits worth knowing

- Search, titles and "Linked from" use pages saved on this device; "Linked from" says how many it could check. Pages outside the
  user's access are not listed and a bound id that is not readable is not named.
- Title matching is local to the source channel by design; broader search is explicit.
- Cross-workspace links are not supported.
- Moving a page does not rewrite links that point at it; they keep working because the id does not change. An old channel-home
  reference to a moved page is not handled natively.
- A page requested while the source screen is gone is created and linked, but is not opened for the person.

## Tests

Core: `WikiLinkTests`, `WikiMoveTests`, `WikiCreateTests` (resolution by id across channels and scopes, rename/move, ambiguous
and unavailable ids, picker search, backlinks by channel rule, code literals in every Markdown form, occurrence binding, retry
and lost-response idempotence, draft and compare-and-set races, offline and refused moves). Editor page: `bun test` in
`BoardEditor/` (`document-wiki.test.js`). iPhone UI: `WikiLinksUITests`. Mac: the in-process check
`-AmbulandoMacThreadRegression -AmbulandoMacWikiLinkCheck -AmbulandoFixtureWiki` on the isolated Test app (a real click on a
stable link, an ambiguous title, a missing page created once and opened).
