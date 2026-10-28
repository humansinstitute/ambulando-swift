# Native chat release matrix (iPhone/iPad build 35, Mac build 24)

Reusable map from each requested chat change to its source, the tests that cover it on each platform and what a release
check must still observe in the final binary. Run evidence (screenshots, logs, device and install state) belongs in the
ignored `tmp/docs/handoffs/` or on the release task, not here. Sample-data tests use the local stand-in for Tower and do not
establish live Tower behaviour.

| # | Change | Source | iPhone/iPad check | Mac check |
| --- | --- | --- | --- | --- |
| 1 | Links visibly styled (Markdown and bare URLs) | `Amb.link`, `InlineText.attributed`, `DocumentSelectableText` | UI `testLinksAreVisibleOpenInAppBrowserAndSafariIsExplicit` (links exposed as links, screenshot blue and underlined) | Same shared renderer; `-AmbulandoMacRichFormattingCheck` renders a link and keeps the body bytes |
| 2 | Links open the in-app browser; Open in Safari explicit; policy and return state kept | `ThreadFocusContainer` / `NewThreadContainer` openURL, `BrowserModel.openInSystemBrowser` | UI `testLinksAre…`, `testOpenInSafariLeavesTheAppOnlyWhenChosen`, `testLinkInAThreadOpensTheInAppBrowser`; existing `BrowserUITests` (consent, HTTPS, draft return) | Same handler on the Mac overlay; manual smoke of a thread link on the installed app |
| 3 | `@` pick closes the list; visible name and structured mention from one value | `MentionCodec.activeQuery(in:excluding:)`, `Composer.activeQuery` | UI `testMentionPickClosesListRecentFirstAndSevenRowCap`; core `testPickedMentionClosesTheListAndTypingOnNeverReopensIt`; `ComposerParityUITests` | Harness asserts `mention.list` closes after a pick and stays closed while typing |
| 4 | Reaction bar like the web, persistent add/remove, counts, own state, spacing | `ReactionBar`, `ReactionEmoji.shaka` | UI `testReactionBarAddRemoveAndPicker`, `testAllSevenReactionsFitPhoneAndAccessibilityText` (wrap bounds and reachable controls at normal/XXXL); `testMessageReactEditDeleteAndSearch`; core `testReactionPickerOffersTheWebsSevenEmojiWithTheirWireNames` | Mac rich harness `REACTION_CONTROLS_PASS` (actual quick add/remove and seven picker buttons), normal/narrow/large-text captures |
| 5 | Rename thread through Tower, safe on refusal and concurrent edits | `WorkspaceSync.renameThread`, `ThreadTitle`, `RenameThreadSheet`, fixture `PATCH /threads/:t` | UI `testRenameThreadUpdatesHeaderListAndHandlesRefusal`, `testRenameConflictShowsCurrentTitleAndKeepsDraft`; core `testRenameThread…` (success, unrelated-version retry, concurrent-title conflict, sync-before-save, 403) | Harness `THREAD_RENAME_PASS` (menu item opens the sheet, rename updates the store and header) |
| 6 | Mac Inbox options menu is compact | `DeckInboxCard.readMenu` | n/a (the pop-up stretching is a Mac control) | Harness `INBOX_MENU_FRAME` width and height limits |
| 7 | Bare `@` lists recently tagged first; iPhone shows at most seven rows | `StoreReader.recentMentions`, `MentionRanking.merge(recent:)`, `MentionPicker` | UI `testMentionPickClosesListRecentFirstAndSevenRowCap` (rick first, list height at most seven rows, remainder by scrolling, composer usable); core `testBareAtListsWhatWasTaggedMostRecentlyFirst…`, `testRecentRecordsResolveCurrentNamesAndEligibilityBeyondDefaultLimit` | Same ranking in core; the Mac list is capped at eight rows |

Release checks that sample tests cannot give: the installed binary's build number and signature, a normal install keeping
the account, NStack settings, caches, drafts and messages, and real Tower behaviour for rename and reactions.
