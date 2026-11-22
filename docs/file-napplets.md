# File-backed daily tracker

Artefacts → New → Daily tracker explicitly creates an empty personal tracker for the signed-in viewer. The app reuses or creates that viewer's self-DM and privately uploads a JSON data File and the reviewed HTML template as a separate File. Opening executes the exact saved HTML version, after a trust and data-use confirmation. No data is imported and no sample health records are created. Code and entries remain NStack Files with normal channel ACLs; authorized administrators and storage operators may access them.

Existing Artefacts, chat File references and personal File pins open the same saved File. Ordinary HTML stays bridge-free. Installed org-data napplets retain their separate contract; canvas HTML does not gain data access.

The File bridge admits the daily-tracker-v1 format and one host-owned tracker binding. Messages contain only read, save or dirty intent, an exact per-document nonce and request ID. An opaque script-only iframe, nonpersistent WebKit storage, CSP, network blocking, navigation rejection and native frame checks isolate code. The frame receives no key, signer, URL or arbitrary request interface.

Every read reauthorizes the code File, bound data File and its self-DM participants. Current version metadata comes from a bounded limit=1 history request; exact bytes must match MIME type, length and SHA-256. The host validates metric types, limits, calendar dates and references, retaining false and zero separately from missing answers. Used definitions cannot disappear or change type. Saves privately upload JSON and publish with the original base_version_id; success requires current-version readback. Conflicts preserve the original draft and require explicit reload. Uncertain outcomes are read back, never blindly retried against a newer base.

Tracker values and unsaved drafts remain in memory; native SQLite, source recovery files and localStorage are not their system of record. Foreground, shared invalidations and a 30-second visible timer reauthorize access while preserving the mounted document. Failed authorization, account/workspace/backend changes, close, pagehide or self-navigation destroy the frame. Pending authorization hides content and rejects writes. Pending saves block voluntary close. Close, reload, source/history and normal section/sidebar navigation guard unsaved work. Source/history removes the bridge and requires fresh trust on reopening. Forced access or identity loss discards memory drafts.

The packaged template in Resources is a byte-identical copy of the shared browser bundle. It is used only for explicit provisioning, then fetched from NStack at runtime. Update it only from the coordinated final package and verify its SHA-256 across hosts.

Local validation includes core model/transport tests and the isolated Mac Test app's `-AmbulandoMacThreadRegression -AmbulandoMacFileNappletCheck` check. The latter executes the packaged UI in the production opaque WebKit host at phone width with synthetic in-memory data only. Local builds and synthetic tests do not establish installation, TestFlight availability or authenticated acceptance on physical devices.

Source versions: Mac 0.1.0 (101), iPhone/iPad 0.1.0 (103).
