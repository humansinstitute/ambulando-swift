#!/bin/zsh
# Regression tests for scripts/mac-install.sh and scripts/build-board-editor.sh, run against stub tools.
#
#   zsh scripts/tests/mac-install-test.sh
#
# Each case copies the scripts into a temporary repository and puts stubs for xcodebuild, xcode-select, sw_vers,
# security, codesign, lipo, ps, osascript, open, mdfind, sleep, ditto and mv first on PATH, so nothing is built,
# signed, quit, opened or installed on this Mac: installs go to a temporary AMBULANDO_INSTALL_DIR and HOME.
set -uo pipefail

REPO=${0:A:h:h:h}
# Without the install-folder override the installer would write to the real /Applications.
grep -q AMBULANDO_INSTALL_DIR "$REPO/scripts/mac-install.sh" || {
    print -u2 "scripts/mac-install.sh does not honour AMBULANDO_INSTALL_DIR; refusing to run it against this Mac."
    exit 1
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mac-install-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
passed=0 failed=0 shown=""

# Writes a minimal Ambulando.app: write_app <path> <version> <build> [bundle id]
write_app() {
    mkdir -p "$1/Contents/MacOS"
    print '#!/bin/sh' > "$1/Contents/MacOS/Ambulando"
    chmod +x "$1/Contents/MacOS/Ambulando"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${4:-studio.otherstuff.ambulando.mac}</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
}

stub() { print -r -- "#!/bin/zsh"$'\n'"$2" > "$BIN/$1"; chmod +x "$BIN/$1" }

# Fresh temporary repository, stubs and install folder for one case. Stub behaviour is chosen with STUB_* variables.
setup() {
    T=$WORK/$1
    ROOT=$T/repo BIN=$T/bin
    mkdir -p "$ROOT/scripts" "$ROOT/Config" "$ROOT/Ambulando.xcodeproj" "$BIN" "$T/home" "$T/Applications"
    cp "$REPO/scripts/mac-install.sh" "$ROOT/scripts/"
    print '<plist version="1.0"><dict/></plist>' > "$ROOT/Config/AmbulandoMac.entitlements"
    : > "$T/calls"; : > "$T/procs"; : > "$T/mdfind"
    cat > "$ROOT/scripts/build-board-editor.sh" <<'EOF'
#!/bin/zsh
case ${STUB_EDITOR:-ok} in
    ok) print "Using bun 1.4.4 (/stub/bun)"; print "Board editor up to date" ;;
    nobun) print -u2 "error: bun is required to build the board editor. Install it from https://bun.sh"; exit 1 ;;
    vite) print "vite v6.4.1 building for production..."; print -u2 "error during build:"; exit 1 ;;
esac
EOF
    chmod +x "$ROOT/scripts/build-board-editor.sh"
    stub xcodebuild '
print -r -- "xcodebuild $*" >> '"$T"'/calls
if [[ $1 == -version ]]; then
    case ${STUB_XCODE:-ok} in
        ok) print "Xcode ${STUB_XCODE_VERSION:-26.3}"; print "Build version 17C529" ;;
        license) print "You have not agreed to the Xcode license agreements. Please run '\''sudo xcodebuild -license'\''."; exit 69 ;;
    esac
    exit 0
fi
derived=${@[${@[(i)-derivedDataPath]}+1]}
case ${STUB_BUILD:-ok} in
    ok) source '"$WORK"'/write_app.zsh; write_app "$derived/Build/Products/Release/Ambulando.app" 0.1.0 ${STUB_BUILD_NUMBER:-5}
        print "** BUILD SUCCEEDED **" ;;
    noerror) print "PhaseScriptExecution Board\\ editor /tmp/Script-1.sh (in target '\''AmbulandoMac'\'')"
        print "error during build:"; print "[vite]: Rollup failed to resolve import"
        print "Command PhaseScriptExecution failed with a nonzero exit code"
        print "** BUILD FAILED **"; print ""; print "The following build commands failed:"
        print "\tPhaseScriptExecution Board\\ editor /tmp/Script-1.sh"; print "(1 failure)"; exit 65 ;;
    swifterror) print "/src/AppModel.swift:10:5: error: cannot find '\''missing'\'' in scope"; print "** BUILD FAILED **"; exit 65 ;;
esac'
    stub xcode-select 'print /Applications/Xcode.app/Contents/Developer'
    stub sw_vers 'print ${STUB_OS:-15.5}'
    stub security '
case ${STUB_IDENTITIES:-none} in
    none) print "     0 valid identities found" ;;
    devid) print "  1) ABCDEF \"Apple Development: Tester (AAAA)\""; print "  2) 123456 \"Developer ID Application: Tester (TEAM)\""; print "     2 valid identities found" ;;
    broken) print -u2 "security: SecKeychainSearchCopyNext: The specified keychain could not be found."; exit 50 ;;
esac'
    stub codesign '
print -r -- "codesign $*" >> '"$T"'/calls
if [[ $* == *--sign* && ${STUB_CODESIGN:-ok} == fail ]]; then print -u2 "$argv[-1]: errSecInternalComponent"; exit 1; fi
exit 0'
    stub lipo 'print "x86_64 arm64"'
    stub ps 'cat '"$T"'/procs'
    stub osascript 'print -r -- "osascript $*" >> '"$T"'/calls; [[ ${STUB_QUIT:-ok} == ok ]] && : > '"$T"'/procs; exit 0'
    stub open '
print -r -- "open $*" >> '"$T"'/calls
app=$1; [[ -n ${STUB_LAUNCHES:-} ]] && app=$STUB_LAUNCHES
print -r -- "4242 $app/Contents/MacOS/Ambulando" >> '"$T"'/procs'
    stub mdfind 'cat '"$T"'/mdfind'
    stub sleep 'exit 0'
    stub pgrep 'exit 1'
    stub ditto '[[ ${STUB_DITTO:-ok} == fail && $argv[-1] == */.Ambulando.app.installing ]] && { print -u2 "ditto: No space left on device"; exit 1; }; exec /usr/bin/ditto "$@"'
    stub mv '[[ ${STUB_MV:-ok} == fail && $argv[1] == */.Ambulando.app.installing ]] && { print -u2 "mv: rename failed"; exit 1; }; exec /bin/mv "$@"'
    for tool in xcodebuild security codesign osascript open ps pgrep mdfind ditto mv; do
        [[ $(PATH=$BIN:/usr/bin:/bin:/usr/sbin command -v $tool) == $BIN/$tool ]] || { print -u2 "stub $tool not first on PATH"; exit 1; }
    done
}

# Runs the installer in the current case: run [args...]; sets OUT and RC.
run() {
    OUT=$(cd "$T" && env -i PATH=$BIN:/usr/bin:/bin:/usr/sbin HOME=$T/home TMPDIR=$T AMBULANDO_INSTALL_DIR=$T/Applications \
        ${STUB_ENV[@]} zsh "$ROOT/scripts/mac-install.sh" "$@" 2>&1)
    RC=$?
}

check() {  # check <description> <condition...>
    local what=$1; shift
    if "$@"; then (( passed++ )); return; fi
    (( failed++ ))
    print -u2 "  FAIL [$CASE] $what"
    if [[ $shown != $CASE ]]; then shown=$CASE; for line in "${(@f)OUT}"; do print -u2 -r -- "    | $line"; done; fi
}
has() { [[ $OUT == *"$1"* ]] }
not() { ! "$@" }
called() { grep -qF -- "$1" "$T/calls" }
installed_build() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$T/Applications/Ambulando.app/Contents/Info.plist" 2>/dev/null }
no_leftovers() { [[ ! -e $T/Applications/.Ambulando.app.installing && ! -e $T/Applications/.Ambulando.app.previous ]] }
start() { CASE=$1; STUB_ENV=("${@:2}"); setup "$CASE"; print -r -- "- $CASE" }

# The xcodebuild stub sources this to create the built app.
functions write_app > "$WORK/write_app.zsh"

# 1. The laptop report: a build failure whose log has no "error:" line used to exit silently after "Building".
start build-fails-without-error-text STUB_BUILD=noerror
write_app "$T/Applications/Ambulando.app" 0.1.0 2
run --no-open
check "exits non-zero" [ $RC -ne 0 ]
check "names the failed step and exit code" has "xcodebuild failed (exit 65)"
check "shows Xcode's failed-command line" has "Command PhaseScriptExecution failed with a nonzero exit code"
check "shows the failed build commands" has "The following build commands failed:"
check "shows the log tail" has "error during build:"
check "says nothing was installed" has "Ambulando was NOT installed or updated"
check "existing app untouched" [ "$(installed_build)" = 2 ]
check "does not sign" not called "codesign --force"

# 2. Compiler errors are listed.
start build-fails-with-compiler-error STUB_BUILD=swifterror
run --no-open
check "exits non-zero" [ $RC -ne 0 ]
check "lists the compiler error" has "error: cannot find 'missing' in scope"
check "no install dir change" [ ! -e "$T/Applications/Ambulando.app" ]

# 3. Missing bun stops before xcodebuild, with the install command.
start board-editor-without-bun STUB_EDITOR=nobun
run
check "exits non-zero" [ $RC -ne 0 ]
check "explains bun is required" has "bun is required"
check "gives the bun install command" has "curl -fsSL https://bun.sh/install | bash"
check "names the stage" has "while preparing the board editor"
check "does not start the app build" not called "xcodebuild -skipPackagePluginValidation"

# 4. A board editor failure without "error:" text is still reported.
start board-editor-vite-failure STUB_EDITOR=vite
run
check "exits non-zero" [ $RC -ne 0 ]
check "shows the editor log" has "error during build:"
check "reports the exit code" has "the board editor did not build (exit 1)"

# 5. Unaccepted Xcode licence.
start xcode-license STUB_XCODE=license
run
check "exits non-zero" [ $RC -ne 0 ]
check "shows xcodebuild's message" has "You have not agreed to the Xcode license"
check "explains how to accept it" has "accept it"

# 6. Older Xcode warns but continues.
start old-xcode-warning STUB_XCODE_VERSION=16.4
run --no-install
check "succeeds" [ $RC -eq 0 ]
check "warns about Xcode 26" has "built and tested with Xcode 26"

# 7. No signing identity: ad-hoc, full install, readback, launch identity and stale copies.
start no-identity-success STUB_IDENTITIES=none
write_app "$T/Applications/Ambulando.app" 0.1.0 2
write_app "$T/home/Applications/Ambulando.app" 0.1.0 2
print -r -- "$T/home/Applications/Ambulando.app" > "$T/mdfind"
run
check "succeeds" [ $RC -eq 0 ]
check "signs ad-hoc" called "--sign - "
check "explains ad-hoc signing" has "Signing ad-hoc: no Developer ID Application or Apple Development identity"
check "shows the replaced version" has "currently 0.1.0 (build 2)"
check "reads back the installed version" has "Installed $T/Applications/Ambulando.app: Ambulando 0.1.0 (build 5)"
check "installed build is 5" [ "$(installed_build)" = 5 ]
check "lists the stale copy with its build" has "$T/home/Applications/Ambulando.app: 0.1.0 (build 2)"
check "reports the running copy" has "Running: $T/Applications/Ambulando.app, Ambulando 0.1.0 (build 5)"
check "points at Settings > About" has "Version 0.1.0 and Build 5"
check "no staging leftovers" no_leftovers
check "stale copy left in place" [ -d "$T/home/Applications/Ambulando.app" ]

# 8. Developer ID preferred, with a secure timestamp.
start developer-id-identity STUB_IDENTITIES=devid
run --no-open
check "succeeds" [ $RC -eq 0 ]
check "uses Developer ID" has "Signing with: Developer ID Application: Tester (TEAM)"
check "uses a secure timestamp" called "--timestamp --entitlements"

# 9. A keychain error in the identity lookup falls back to ad-hoc instead of exiting silently.
start identity-lookup-error STUB_IDENTITIES=broken
run --no-open
check "succeeds" [ $RC -eq 0 ]
check "signs ad-hoc" called "--sign - "

# 10. Signing failure: actionable, nothing installed.
start signing-fails STUB_IDENTITIES=devid STUB_CODESIGN=fail
write_app "$T/Applications/Ambulando.app" 0.1.0 2
run
check "exits non-zero" [ $RC -ne 0 ]
check "shows codesign's error" has "errSecInternalComponent"
check "suggests an alternative identity" has "AMBULANDO_SIGN_IDENTITY=- zsh scripts/mac-install.sh"
check "existing app untouched" [ "$(installed_build)" = 2 ]

# 11. Copy failure: existing app unchanged, staging removed.
start copy-fails STUB_DITTO=fail
write_app "$T/Applications/Ambulando.app" 0.1.0 2
run
check "exits non-zero" [ $RC -ne 0 ]
check "shows the copy error" has "No space left on device"
check "existing app untouched" [ "$(installed_build)" = 2 ]
check "no staging leftovers" no_leftovers

# 12. Swap failure: the previous app is put back.
start swap-fails STUB_MV=fail
write_app "$T/Applications/Ambulando.app" 0.1.0 2
run
check "exits non-zero" [ $RC -ne 0 ]
check "says the previous app was put back" has "the previous app was put back"
check "previous app restored" [ "$(installed_build)" = 2 ]
check "no staging leftovers" no_leftovers

# 13. A running copy that does not quit: refuse, nothing changed.
start running-refuses-to-quit STUB_QUIT=no
write_app "$T/Applications/Ambulando.app" 0.1.0 2
print -r -- "777 $T/Applications/Ambulando.app/Contents/MacOS/Ambulando" > "$T/procs"
run
check "exits non-zero" [ $RC -ne 0 ]
check "asks to quit it" has "Ambulando is still running"
check "asked it to quit politely" called "tell application id \"studio.otherstuff.ambulando.mac\" to quit"
check "existing app untouched" [ "$(installed_build)" = 2 ]

# 14. A running copy elsewhere is quit too; a Debug build (other bundle id) is ignored.
start running-copy-elsewhere-quits
write_app "$T/home/Applications/Ambulando.app" 0.1.0 2
write_app "$T/debug/Ambulando.app" 0.1.0 9 studio.otherstuff.ambulando.mac.debug
print -r -- "777 $T/home/Applications/Ambulando.app/Contents/MacOS/Ambulando" > "$T/procs"
run --no-open
check "succeeds" [ $RC -eq 0 ]
check "quit the running copy" has "Quitting the running Ambulando"
start debug-build-running-is-ignored STUB_QUIT=no
write_app "$T/debug/Ambulando.app" 0.1.0 9 studio.otherstuff.ambulando.mac.debug
print -r -- "778 $T/debug/Ambulando.app/Contents/MacOS/Ambulando" > "$T/procs"
run --no-open
check "succeeds" [ $RC -eq 0 ]
check "does not try to quit it" not called osascript

# 15. Opening starts a different (stale) copy: reported as a failure after install.
start different-copy-launches
write_app "$T/home/Applications/Ambulando.app" 0.1.0 2
STUB_ENV+=(STUB_LAUNCHES=$T/home/Applications/Ambulando.app)
run
check "exits non-zero" [ $RC -ne 0 ]
check "names the copy that runs" has "a different copy is running: $T/home/Applications/Ambulando.app, 0.1.0 (build 2)"
check "says the install itself happened" has "$T/Applications/Ambulando.app was installed before this step"
check "new app installed" [ "$(installed_build)" = 5 ]

# 16. macOS older than the app's minimum: refuse before installing.
start macos-too-old STUB_OS=14.7
run
check "exits non-zero" [ $RC -ne 0 ]
check "explains the minimum" has "needs macOS 15.0 or later; this Mac runs 14.7"
check "nothing installed" [ ! -e "$T/Applications/Ambulando.app" ]

# 17. An interrupted earlier install (app moved aside, not replaced) is restored, then updated.
start interrupted-earlier-install
write_app "$T/Applications/.Ambulando.app.previous" 0.1.0 2
run --no-open
check "succeeds" [ $RC -eq 0 ]
check "restores the set-aside app first" has "Restoring $T/Applications/Ambulando.app"
check "then installs build 5" [ "$(installed_build)" = 5 ]
check "no staging leftovers" no_leftovers

# 18. --no-install builds and signs only.
start no-install
run --no-install
check "succeeds" [ $RC -eq 0 ]
check "built line" has "Built Ambulando 0.1.0 (build 5)"
check "nothing installed" [ ! -e "$T/Applications/Ambulando.app" ]
check "nothing opened" not called "open "

# 19. build-board-editor.sh: bun install failure is explained (stub bun in a temporary HOME).
CASE=board-editor-bun-install-failure; print -r -- "- $CASE"
E=$WORK/$CASE; mkdir -p "$E/scripts" "$E/BoardEditor/web" "$E/home/.bun/bin"
cp "$REPO/scripts/build-board-editor.sh" "$E/scripts/"
print '{}' > "$E/BoardEditor/package.json"; print '{}' > "$E/BoardEditor/bun.lock"; print '' > "$E/BoardEditor/vite.config.mjs"
print 'x' > "$E/BoardEditor/web/main.js"
print '#!/bin/zsh\n[[ $1 == --version ]] && { print 1.0.0; exit 0 }\n[[ $1 == install ]] && { print -u2 "lockfile could not be read"; exit 1 }\nexit 0' > "$E/home/.bun/bin/bun"
chmod +x "$E/home/.bun/bin/bun"
OUT=$(env -i PATH=/usr/bin:/bin HOME=$E/home zsh "$E/scripts/build-board-editor.sh" 2>&1); RC=$?
check "exits non-zero" [ $RC -ne 0 ]
check "prints the bun version" has "Using bun 1.0.0"
check "shows bun's own message" has "lockfile could not be read"
check "explains the failure" has "bun install --frozen-lockfile failed (exit 1)"
check "suggests updating bun" has "bun upgrade"

print "\n$passed passed, $failed failed"
(( failed == 0 ))
