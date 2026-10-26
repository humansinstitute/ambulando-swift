#!/bin/zsh
# Builds BoardEditor/dist: the Excalidraw board editor page the iPhone, iPad and Mac apps embed (BoardEditor/README.md).
# Dependencies are the exact versions in BoardEditor/bun.lock. Skips the build when dist/ already matches the
# current sources and lockfile. Xcode runs this for the app targets (see board-editor-xcode.sh); run it by hand to
# check a change.
set -euo pipefail
root=${0:A:h:h}
editor=$root/BoardEditor
path=($HOME/.bun/bin /opt/homebrew/bin /usr/local/bin $path)
command -v bun >/dev/null || {
  print -u2 "error: bun is required to build the board editor. Install it from https://bun.sh"
  print -u2 "(curl -fsSL https://bun.sh/install | bash), open a new Terminal window and run this again."
  exit 1
}
print "Using bun $(bun --version) ($(command -v bun))"

# bun.lock's text format is versioned independently of package.json. Bun 1.2 and
# older report "Unknown lockfile version" for the v2 lockfile and then fail the
# frozen install with the misleading claim that the lockfile changed. Detect
# that known incompatibility before touching node_modules so the top-level Mac
# installer can explain exactly how to recover.
lock_version=$(sed -n 's/.*"lockfileVersion":[[:space:]]*\([0-9][0-9]*\)[,}].*/\1/p' "$editor/bun.lock" | head -1)
bun_version=$(bun --version)
if [[ $lock_version == 2 && $bun_version == (0|1.0.*|1.1.*|1.2.*) ]]; then
  print -u2 "error: bun $bun_version cannot read BoardEditor/bun.lock (lockfile version 2)."
  print -u2 "Upgrade bun to 1.3 or newer with: bun upgrade"
  exit 1
fi

# Fingerprint of everything that determines the output.
stamp=$(cd $editor && { cat package.json bun.lock vite.config.mjs; find web -type f | LC_ALL=C sort | xargs cat } | shasum -a 256 | cut -d' ' -f1)
if [[ -f $editor/dist/.build-stamp && $(<$editor/dist/.build-stamp) == $stamp && -f $editor/dist/index.html ]]; then
  print "Board editor up to date"
  exit 0
fi
cd $editor
bun install --frozen-lockfile || {
  rc=$?
  print -u2 "error: bun install --frozen-lockfile failed (exit $rc). It needs network access to the npm registry and a"
  print -u2 "bun that can read BoardEditor/bun.lock; update bun with: bun upgrade"
  exit $rc
}
bun x --bun vite build --config vite.config.mjs || {
  rc=$?
  print -u2 "error: the board editor build (vite) failed (exit $rc); the messages above say why."
  exit $rc
}
print -n $stamp > dist/.build-stamp
print "Board editor built: $(du -sh dist | cut -f1)"
