#!/bin/zsh
# Writes dist/ambulando-native-source-<commit>.zip: the committed tree (git archive), for building on another Mac
# without access to this repository. Uncommitted changes are not included.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
commit=$(git rev-parse --short=12 HEAD)
mkdir -p dist
out=dist/ambulando-native-source-$commit.zip
git archive --format=zip --prefix=ambulando-native-ip/ -o "$out" HEAD
shasum -a 256 "$out" | tee "$out.sha256"
