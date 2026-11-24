# Mac voice recording (source build 115)

The composer microphone button opens a native recorder. Choose System default or
an OS-discovered microphone before recording. Preference and the actual attached
capture input are separate: an unavailable preference falls back to the current
system input with an explanation. System default resolves when the clip starts;
it does not switch a clip when the OS default changes midway.

The live level comes from the recording file output's audio channels, using a
quiet floor at −60 dB and no decorative animation. The same capture writes AAC
audio to M4A. A recording-start callback confirms the active input; elapsed time
comes from recorded duration. Input choice stays locked during capture and file
finalization. Limits are ten minutes or 90 MB.

Stop finalizes the file before Play or Attach recording becomes available. Cancel,
leaving the composer, changing targets or entering message edit stops capture and
removes the unaccepted temporary clip. Disconnection stops rather than silently
changing inputs midway; any playable partial clip is retained for review. Input
refresh is explicit and does not start capture. Denied permission explains the
macOS privacy setting. Meter polling stops with capture; no permanent device
observer or second capture runs.

The recorder snapshots its conversation, connection, workspace, app and unlocked
identity. Context or lock changes cancel it; attachment rechecks the original
context and current composer before handing bytes to uploads. The microphone
control is unavailable while editing, uploading or without attachment authority.

Attach recording copies the bytes into the existing composer file-upload path.
Upload placeholders, retry, target-bound drafts and explicit Send retain their
existing behavior. Attachment failure keeps the review clip. This Mac client has
no transcription pipeline: recordings are file attachments.
No backend route or service change is required. iPhone recording remains a parity
gap and is not delivered by this Mac implementation.

Validation: compile the Mac target and run `scripts/tests/mac-voice-recording.swift`
with the recorder source. The standalone check uses generated audio and does not
request microphone permission. It covers silence/level mapping, actual input vs
preference, disconnection and finalized-file review/cancel cleanup. It cannot
establish physical microphone capture, unplug quality, permissions UI, live upload
or installation. Those require device acceptance on Pete's source-built Mac app.
