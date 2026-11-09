#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
evidence="$PWD/tmp/docs/handoffs/chat-selection"
mkdir -p "$evidence"
CHAT_SELECTION_FIXTURE="$evidence/fixture.html" swift test --package-path AmbulandoCore --filter ChatSelectionTests
swiftc -parse-as-library scripts/tests/chat-selection-webkit.swift -o "$evidence/webkit-check"
"$evidence/webkit-check" "$PWD" "$evidence/fixture.html"
