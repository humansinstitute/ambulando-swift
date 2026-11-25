# iPhone/iPad voice recording (source 116)

The composer microphone button opens recording controls. Use **Refresh inputs**
to grant microphone access and list the audio session's available inputs, then
choose a preferred microphone or **System default** before starting. The preference
is a request; **Active input** comes separately from the session's current input
route after recording begins. Missing preferences fall back to the system route;
an unknown route stays **Unknown**. OS routing policy controls which inputs are
available, including compatible wired/USB/Bluetooth inputs.

One AVAudioRecorder writes AAC/M4A and supplies its own average-power meter.
Silence at or below −60 dB stays at zero; no decorative animation runs, including
with reduced motion. Recording state, elapsed time and input-level accessibility
labels are available. Clips are limited to ten minutes. Choice is locked until
the clip finishes, including review; cancel it to choose for a new clip.

**Stop** finalizes the clip for **Play**, **Attach recording** or **Cancel recording**.
A route change, interruption, backgrounding or hiding the recording panel stops
capture and retains any playable partial clip for review. There is no automatic
resume or send. Returning to the retained composer reopens that clip. The clip is
not a durable recording draft: cancelling, changing account/workspace/conversation,
locking, editing a message, destruction of the composer or terminating the app
can remove an unattached clip. Attach it to use the existing upload/draft recovery
flow. Permission results from a closed/cancelled recording cannot start capture.

Capture meter timers and route/interruption observers detach on stop; audio-session
ownership is released on finalization, cancellation, closing and backgrounding.
Refresh does not start capture. Microphone selection uses a temporarily active
recording session; it can change audio playback routing while controls are open.

Attachment copies the finalized file through the existing composer upload path.
Failure keeps the review clip; accepted uploads use existing placeholders/retry,
target-bound drafts and explicit **Send**. This native client has no transcription
pipeline. No server contract or Mac recorder behavior changes are required.

## Validation and acceptance

Run `zsh scripts/tests/phone-voice-recording.sh` on macOS. It compiles
`scripts/tests/phone-voice-recording.swift` with the recorder source and
`-D VOICE_HOST_TEST`, then removes its disposable executable. It uses a fake capture driver and generated PCM files
to check permission races, start failures, silence/nonzero levels, actual-route
versus preference/fallback/unknown reporting, interruption/cancel/close cleanup
and review retention. It does not exercise AVAudioSession or physical capture.
The existing ComposerUploadTests exercise audio attachment, explicit Send,
offline retry, draft recovery and target isolation with synthetic transport.

A focused iOS SDK typecheck of PhoneVoiceRecorder.swift checks the actual iOS
adapter and SwiftUI controls; parsing the app sources checks syntax only. Neither
substitutes for full application typechecking, building, UI tests or installation.
With no eligible Xcode destination, those checks remain open. Physical microphone,
headset/Bluetooth/USB selection/disconnection, visible speech response, permission
UI, interruptions, background/foreground UI and authenticated upload require
separate iPhone/iPad acceptance. Source 116 is not a TestFlight/device delivery.
