# Channel artefacts

The Artefacts section includes ordinary documents and saved Excalidraw/HTML Files in the current workspace, scope or channel. Type and title filters narrow the list. The creation menu offers Document, Whiteboard and HTML; presentation and spreadsheet editors are not offered.

Documents retain their existing document IDs, editor, history and links. Rich artefacts retain File IDs, channel permissions and immutable File versions. Channel entries, chat File references and personal File pins open the same saved content. Existing canvas whiteboards share the same editor session and recovery draft with directly opened Files.

Whiteboards use the bundled Excalidraw editor with the existing explicit Save, stale-save handling, version history and restore controls. HTML runs in a nonpersistent WebKit view with no signer or native message bridge, network access, forms, frames or navigation. Authorized manifest images are read through exact private File-version routes and checked for size and SHA-256 before entering the sandbox as image data URLs.

HTML Source & history loads exact original UTF-8 File bytes, including any manifest. It does not save injected preview code or rewritten asset URLs. Saving publishes a new version against the original base. Failed saves retain the source; connection/workspace/File-scoped recovery drafts survive closing the sheet. Browsing versions is disabled while a draft is changed. An explicit Keep draft on latest revision action retains the source against a freshly read base for review before Save. This does not merge concurrent source edits automatically.

New rich Files carry the built-in v1 artefact descriptor. The application selects built-in renderers only; metadata never loads remote editors or grants permissions. Existing files remain discoverable by projected media type and legacy filename/metadata inference. The server still validates the actual format and permissions.

Native direct HTML and File pins require the additive NStack channel-artefacts v1 contract. Devices connected to an older backend show the read/write failure rather than creating a separate catalogue. File discovery retains the existing bounded channel Files sync; very large channels may require backend pagination in a later change.

Build versions for this change: Mac 0.1.0 (100), iPhone/iPad 0.1.0 (102). Build numbers in source do not establish installation or device acceptance.
