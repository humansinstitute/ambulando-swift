# Composer, personal pin ordering and browser files

The shared native iPhone/Mac client uses Tower's existing personal pin contract. Hold and drag a pinned card's main
content onto the upper/lower half of another row to insert before/after it, including after the last item. A subtle
insertion line appears only while dragging over a row. Idle cards retain their resource icon, title and Unpin, with
no arrangement controls or instructions. Accessibility actions offer Move up/down/to end; Command–Option–Up/Down
moves the focused card. A short tap still opens the record and Unpin remains independent. The queue permits one pending
move and waits for pending selection changes. Order errors appear only on failure; a stale move requires discarding
it and deliberately moving again.

`POST /me/pin-order` carries the typed resource, its observed `expected_row_version`, a typed/versioned `before`
anchor (or null), and an immutable `mutation_id`. The existing signed write queue sends it; WorkspaceSync owns reads.
The `personal_pin_order_version: 1` capability on the main `record-sync` envelope is required (the priority pin feed does not advertise it). The response updates the existing private pin rows;
there is no second preference store. Older acknowledgements cannot overwrite newer pin versions or unpin tombstones.
Stale membership changes likewise do not silently rebase onto another device's newer unpin. New pins retain Tower's
new-pin-first ordering. A move made offline waits in the same durable queue and may visibly conflict on reconnect.

The rounded chat composer surface focuses the same native editor when its padding is clicked or tapped. The editor
keeps its selection and native text gestures; attachment, mention, keyboard and Send controls retain separate targets.
The shell places record controls in Search, Notifications, Pin, Browser, Avatar order. Pin appears only for a pinnable
record.

## Embedded browser file behavior

The reference audit used the current Nostr Browser checkout (`nbrowser`), including `browser_download.dart`,
`browser_screen.dart`, `webview_file_picker.dart`, and the iOS/Mac native export handlers. Its downloader handles direct
file links, download attributes and response signals with filename selection, redirect checks, cancellation and file
export. Its Dart downloader accepts HTTP(S) only; Android has an explicit platform file-picker adapter.

Ambulando keeps its existing HTTPS policy and WebKit session rather than copying an alternate HTTP client or signer:

- Download attributes, attachment responses and unsupported main-frame MIME types use `WKDownload`, retaining the
  browser's website cookies. Redirects must remain HTTPS; failed HTTP responses are reported instead of saved as files.
- User-initiated blob/data file links are download-only, bound to the HTTPS source frame. A blob must name that same
  origin. They never become a page with Nostr signing authority.
- One transfer at a time, 100 MB maximum, sanitized basename in a random temporary directory, explicit Save/export,
  cancellation, and cleanup. Reading completed bytes runs off the main actor. Closing the tab/browser or replacing the
  document cancels an active transfer. Save cancellation leaves the web page and Ambulando draft intact.
- Mac implements WebKit's native open panel, including multiple selection and directory flags. iPhone retains WebKit's
  native file input/photo picker. The browser never searches the filesystem or uploads a file without picker selection.
- Existing HTTPS popups/tabs, alert/confirm handling, and per-origin/per-document NIP-07 approval remain. Browser data is
  separate from sandboxed HTML naplets. No native filesystem, Tower-auth, encryption, clipboard or FIPS bridge is added.
  Unsupported web APIs remain WebKit's normal unsupported APIs; no broad permissions are granted for parity.

Source, automated fixture UI, real WebKit file bytes, live Tower synchronization, signed builds and physical-device
installs are separate evidence categories recorded on the release task. Build success does not establish live behavior.
