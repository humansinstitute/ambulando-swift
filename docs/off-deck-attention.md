# Off-deck attention

Archived conversations/documents and archived or cancelled tasks do not contribute
unread channel badges or Deck attention. Unknown parent records retain their real
unread state: paging, filtering and an unloaded card are not lifecycle evidence.
Completed tasks keep the existing unread exception.

The shared SQLite read projection checks only stored lifecycle state. It retains
activity and read versions, emits no automatic read receipt and works offline after
reopening the cache. Sidebar observers include parent lifecycle changes on iPhone
and Mac. Restoring an item restores retained unread attention unless explicitly
acknowledged in the meantime.

Deck mark-all reads persisted resource positions within the selected context,
including hidden items and active resources absent from the rendered cards. Search,
family filters and page limits do not narrow the explicit action. Existing signed
read commands preserve other readers' state. Mark-all before restoring a resource
keeps previously acknowledged activity read; newer activity can become unread.

`UnreadAttentionTests` covers hidden-only and mixed channel attention, missing
parents, stale view-state sync, reopen and restoration. `DeckActivityTests` covers
the completed-task exception and context selection. Physical installation and
real-account multi-device verification remain separate from source/build checks.
