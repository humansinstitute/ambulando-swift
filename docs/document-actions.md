# Native document actions

The document reader’s **Document actions** menu on iPhone, iPad and Mac includes Markdown and PDF export, FD Ref, Versioning, Move, Archive document and Delete document. Android implementation is deferred.

Exports use the saved document shown in reading mode. When editing, the current edit is captured first and exported without publishing it. Markdown contains the title followed by the document’s Markdown representation. The native save dialog lets the user choose a destination; cancelling does not alter the document.

PDF uses the bundled rich-document renderer, including its supported tables, text styles and images. Stored images are loaded through the native authenticated file cache. Missing or unsupported images cause an explicit error rather than an incomplete successful export. The exporter produces A4 pages, keeping ordinary blocks, table rows and text lines together where they fit. An unusually tall individual block or row may span pages. The export limit is 250 pages. External image URLs blocked by the renderer cannot be exported. PDF links retain their visible text, but interactive link annotations are not preserved.

**FD Ref** copies the same escaped `@[Title](mention:document:<id>)` reference as web. A reference identifies the document; it grants no access.

**Versioning** loads Tower’s canonical shared document history, independently of this device’s recovery drafts. It shows version metadata, a formatted preview or Markdown source, source copy and comparison with the previous version. Comparison presents the two complete versions rather than a line diff. Missing historical bodies are labelled unavailable and cannot be restored.

**Restore as draft** preserves existing work in the native review journal, fetches the current shared head and opens the selected historical body as a draft. Review and explicitly Save to publish a new shared version using the normal edit lease, body hash and row-version safeguards. This deliberate Save step differs from web’s immediate restore-and-save behavior. Restoration does not remove old shared versions or local recovery history.

Archive and delete use Tower’s existing version-guarded contracts and remain subject to server permissions. Both require confirmation. Archive removes the document from active lists while keeping shared content and history. Delete removes it from the shared workspace for everyone with access; the confirmation explains that consequence. Local drafts remain retained. These operations are online and are never queued or automatically retried after an uncertain response. A missing or rejected response is reported without claiming success.

Pushed source, local builds, simulated checks and installation on a physical device are separate delivery states. Release evidence must identify which were actually verified.
