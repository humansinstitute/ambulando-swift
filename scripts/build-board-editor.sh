#!/bin/zsh
# Builds BoardEditor/dist: the Excalidraw board editor page the iPhone, iPad and Mac apps embed (BoardEditor/README.md).
# Dependencies are the exact versions in BoardEditor/bun.lock. Skips the build when dist/ already matches the
# current sources and lockfile. Xcode runs this for the app targets (see board-editor-xcode.sh); run it by hand to
# check a change.
set -euo pipefail
root=${0:A:h:h}
editor=$root/BoardEditor
path=($HOME/.bun/bin /opt/homebrew/bin /usr/local/bin $path)
command -v bun >/dev/null || { print -u2 "error: bun is required to build the board editor (https://bun.sh)."; exit 1 }

# Fingerprint of everything that determines the output.
stamp=$(cd $editor && { cat package.json bun.lock vite.config.mjs; find web -type f | LC_ALL=C sort | xargs cat } | shasum -a 256 | cut -d' ' -f1)
if [[ -f $editor/dist/.build-stamp && $(<$editor/dist/.build-stamp) == $stamp && -f $editor/dist/index.html ]]; then
  exit 0
fi
cd $editor
bun install --frozen-lockfile --silent
bun x --bun vite build --config vite.config.mjs
print -n $stamp > dist/.build-stamp
print "Board editor built: $(du -sh dist | cut -f1)"
