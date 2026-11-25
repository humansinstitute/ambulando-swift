#!/bin/zsh
# Synthetic host checks only; no microphone permission, installation or device capture.
set -euo pipefail
root=${0:A:h:h:h}
task_output=$(mktemp -d "${TMPDIR:-/tmp}/ambulando-phone-voice.XXXXXX")
trap 'rm -rf -- "$task_output"' EXIT
swiftc -swift-version 6 -D VOICE_HOST_TEST -parse-as-library \
  "$root/Ambulando/Views/PhoneVoiceRecorder.swift" \
  "$root/scripts/tests/phone-voice-recording.swift" -o "$task_output/checks"
"$task_output/checks"
