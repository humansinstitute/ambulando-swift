#!/bin/zsh
# Builds the native Mac app (Release, Apple Silicon + Intel), signs it, installs it and optionally packages a ZIP.
#
#   scripts/mac-install.sh                 build, sign, install to /Applications (or ~/Applications), open it
#   scripts/mac-install.sh --package       also write dist/Ambulando-mac-<version>-<build>.zip and its SHA-256
#   scripts/mac-install.sh --no-install    build (and package) only
#   scripts/mac-install.sh --no-open       install without opening the app
#
# Needs Xcode (selected with xcode-select) and bun (https://bun.sh) for the embedded board editor; see docs/mac.md.
# Every step says what it is doing; if one fails the script prints why, the relevant log lines and whether anything
# in Applications changed, and exits non-zero. After installing it reads the version and build back from the
# installed app, lists other Ambulando copies on this Mac (which would open an older version) and, when it opens the
# app, reports which copy is actually running.
#
# Signing: AMBULANDO_SIGN_IDENTITY if set, otherwise the first "Developer ID Application", then "Apple Development"
# identity in your keychain, otherwise ad-hoc. Only the identity's name is read; nothing is exported. A stable identity
# matters: macOS lets the app that created a Keychain item read it without asking, and "the same app" means the same
# signer. With ad-hoc signing every rebuild is a new signer, so after an update macOS asks for your login password once
# (choose Always Allow). The app is not notarized by this script.
#
# AMBULANDO_INSTALL_DIR installs into that folder instead of /Applications.
#
# Your data is kept across reinstalls: it lives in the app's sandbox container
# (~/Library/Containers/studio.otherstuff.ambulando.mac), not inside Ambulando.app.
set -euo pipefail
autoload -Uz is-at-least

ROOT=${0:A:h:h}
cd "$ROOT"

package=0 install=1 open_app=1
for arg in "$@"; do
    case $arg in
        --package) package=1 ;;
        --no-install) install=0 ;;
        --no-open) open_app=0 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) print -u2 "Unknown option: $arg"; exit 2 ;;
    esac
done

DERIVED=$ROOT/build/mac-release
APP=$DERIVED/Build/Products/Release/Ambulando.app
LOG=$ROOT/build/mac-release.log
EDITOR_LOG=$ROOT/build/board-editor.log

# What the script is doing, for the message printed if it stops. installed is the app's path once it has been replaced.
stage="checking prerequisites" installed=""
report_exit() {
    local rc=$?
    (( rc == 0 )) && return
    print -u2 ""
    if [[ -n $installed ]]; then
        print -u2 "==> FAILED (exit $rc) while $stage. $installed was installed before this step."
    else
        print -u2 "==> FAILED (exit $rc) while $stage. Ambulando was NOT installed or updated;"
        print -u2 "    any Ambulando already in Applications is unchanged, and your data and identity are untouched."
    fi
    print -u2 "    To save everything this script printed: zsh scripts/mac-install.sh 2>&1 | tee ~/Desktop/ambulando-install.txt"
}
trap report_exit EXIT

fail() { print -u2 "error: $*"; exit 1 }
show_tail() {  # file, line count
    print -u2 -r -- "---- last $2 lines of $1 ----"
    tail -n "$2" "$1" >&2 || true
    print -u2 -r -- "---- end of $1 ----"
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null }
describe_app() {  # "0.1.0 (build 5)" for an Ambulando.app, or "unknown version"
    local v b
    v=$(plist_value "$1" CFBundleShortVersionString) || v=""
    b=$(plist_value "$1" CFBundleVersion) || b=""
    if [[ -n $v ]]; then print -r -- "$v (build $b)"; else print -r -- "unknown version"; fi
}

[[ $(uname -s) == Darwin ]] || fail "macOS is required."
mkdir -p "$ROOT/build"

xcode_out=$(xcodebuild -version 2>&1) || {
    print -u2 "$xcode_out"
    developer_dir=$(xcode-select -p 2>/dev/null) || developer_dir="(none)"
    if [[ $xcode_out == *[Ll]icense* ]]; then
        print -u2 "Xcode's license has not been accepted on this Mac. Open Xcode once and accept it (or run"
        print -u2 "sudo xcodebuild -license), then run this again."
    elif [[ $developer_dir == *CommandLineTools* || $xcode_out == *"requires Xcode"* ]]; then
        print -u2 "Only the Command Line Tools are selected ($developer_dir); the full Xcode app is needed."
        print -u2 "Install Xcode, open it once, then: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    else
        print -u2 "Install Xcode, open it once, then select it: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    fi
    fail "xcodebuild is not usable (selected developer directory: $developer_dir)."
}
xcode_line=${${(f)xcode_out}[1]}
print "==> Using $xcode_line ($(xcode-select -p 2>/dev/null || print unknown)) on macOS $(sw_vers -productVersion)"
xcode_major=${${xcode_line#Xcode }%%.*}
if [[ $xcode_major == <-> ]] && (( xcode_major < 26 )); then
    print -u2 "warning: this project is built and tested with Xcode 26; $xcode_line may fail to compile it."
fi

# The app targets also run this from an Xcode build phase, where a failure is easy to miss in the log; running it
# first shows its result directly. Xcode's run then finds it up to date.
stage="preparing the board editor (scripts/build-board-editor.sh, needs bun)"
print "==> Preparing the board editor; log: $EDITOR_LOG"
editor_rc=0
"$ROOT/scripts/build-board-editor.sh" >"$EDITOR_LOG" 2>&1 || editor_rc=$?
if (( editor_rc )); then
    show_tail "$EDITOR_LOG" 30
    if grep -q "bun is required" "$EDITOR_LOG"; then
        print -u2 "Install bun (https://bun.sh): curl -fsSL https://bun.sh/install | bash"
        print -u2 "then open a new Terminal window and run this again."
    elif grep -q "cannot read BoardEditor/bun.lock" "$EDITOR_LOG"; then
        print -u2 "Upgrade bun, then run this installer again: bun upgrade"
    fi
    fail "the board editor did not build (exit $editor_rc); the lines above say why."
fi
grep -E "^(Using bun|Board editor)" "$EDITOR_LOG" | sed 's/^/    /' || true

stage="building the app with xcodebuild"
print "==> Building Ambulando for Mac (Release, arm64 + x86_64); log: $LOG"
print "    This takes several minutes, longer the first time. To watch it: tail -f $LOG"
build_rc=0
xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme AmbulandoMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO build >"$LOG" 2>&1 \
    || build_rc=$?
if (( build_rc )); then
    print -u2 "xcodebuild failed (exit $build_rc)."
    errors=$(grep -E "error:|failed with a nonzero exit code" "$LOG" | sort -u | head -20) || errors=""
    if [[ -n $errors ]]; then
        print -u2 "Errors in the log:"
        print -u2 -r -- "$errors"
    fi
    failed=$(sed -n '/The following build commands failed:/,$p' "$LOG" | head -12) || failed=""
    [[ -n $failed ]] && print -u2 -r -- "$failed"
    show_tail "$LOG" 40
    if grep -q "Could not resolve package dependencies" "$LOG"; then
        print -u2 "Swift packages could not be fetched: check the network connection to github.com and run this again."
    fi
    fail "the app did not build; see the lines above and $LOG."
fi
[[ -d $APP ]] || fail "xcodebuild reported success but $APP does not exist."

stage="choosing a signing identity"
identity=${AMBULANDO_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
    identities=$(security find-identity -v -p codesigning 2>/dev/null) || identities=""
    for kind in "Developer ID Application" "Apple Development"; do
        for line in ${(f)identities}; do
            if [[ $line =~ "\"($kind:[^\"]*)\"" ]]; then identity=$match[1]; break; fi
        done
        [[ -n $identity ]] && break
    done
fi
if [[ $identity == - ]]; then
    print "==> Signing ad-hoc (AMBULANDO_SIGN_IDENTITY=-)."
elif [[ -z $identity ]]; then
    identity=-
    print "==> Signing ad-hoc: no Developer ID Application or Apple Development identity found in your keychain."
fi
if [[ $identity == - ]]; then
    print "    After this update macOS asks once for your login password so Ambulando can read its Keychain item;"
    print "    choose Always Allow."
else
    print "==> Signing with: $identity"
fi

stage="signing the app"
# Developer ID signatures carry Apple's secure timestamp (needed for notarization); others do not need one.
timestamp=--timestamp=none
[[ $identity == "Developer ID Application"* ]] && timestamp=--timestamp
sign_out=$(codesign --force --options runtime $timestamp --entitlements Config/AmbulandoMac.entitlements \
    --sign "$identity" "$APP" 2>&1) || {
    print -u2 -r -- "$sign_out"
    if [[ $identity != - ]]; then
        print -u2 "codesign could not use \"$identity\". If the login keychain is locked or the certificate's private"
        print -u2 "key is missing, unlock it in Keychain Access, or choose another identity, for example ad-hoc:"
        print -u2 "  AMBULANDO_SIGN_IDENTITY=- zsh scripts/mac-install.sh"
        [[ $sign_out == *ambiguous* ]] && print -u2 "Several certificates share that name: set AMBULANDO_SIGN_IDENTITY to its SHA-1 hash (security find-identity -v -p codesigning)."
    fi
    fail "signing failed."
}
verify_out=$(codesign --verify --strict --deep "$APP" 2>&1) || { print -u2 -r -- "$verify_out"; fail "the signed app did not verify."; }

stage="reading the built app's version"
version=$(plist_value "$APP" CFBundleShortVersionString) || fail "cannot read the version from $APP."
build=$(plist_value "$APP" CFBundleVersion) || fail "cannot read the build number from $APP."
bundle_id=$(plist_value "$APP" CFBundleIdentifier) || fail "cannot read the bundle identifier from $APP."
min_os=$(plist_value "$APP" LSMinimumSystemVersion) || min_os=""
archs=$(lipo -archs "$APP/Contents/MacOS/Ambulando" 2>/dev/null) || archs="unknown"
print "==> Built Ambulando $version (build $build), architectures: $archs"

if (( package )); then
    stage="packaging the ZIP"
    mkdir -p dist
    zip=dist/Ambulando-mac-$version-$build.zip
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"
    shasum -a 256 "$zip" | tee "$zip.sha256"
fi

(( install )) || exit 0

stage="checking this Mac can run the app"
os_version=$(sw_vers -productVersion)
if [[ -n $min_os ]] && ! is-at-least "$min_os" "$os_version"; then
    fail "this build needs macOS $min_os or later; this Mac runs $os_version."
fi

# Running copies of this app (any location): "pid path-to-Ambulando.app" per line.
running_copies() {
    local pid exe app id
    ps -axo pid=,comm= 2>/dev/null | while read -r pid exe; do
        [[ $exe == */Ambulando.app/Contents/MacOS/Ambulando ]] || continue
        app=${exe%/Contents/MacOS/Ambulando}
        id=$(plist_value "$app" CFBundleIdentifier) || id=""
        if [[ $id == $bundle_id ]]; then print -r -- "$pid $app"; fi
    done
    return 0
}

if [[ -n ${AMBULANDO_INSTALL_DIR:-} ]]; then
    target=$AMBULANDO_INSTALL_DIR
    mkdir -p "$target"
elif [[ -w /Applications ]]; then
    target=/Applications
else
    target=$HOME/Applications
    mkdir -p "$target"
    print "==> /Applications is not writable for this account; installing to $target instead."
fi
dest=$target/Ambulando.app

stage="quitting the running Ambulando"
if [[ -n $(running_copies) ]]; then
    print "==> Quitting the running Ambulando (unsent messages and changes stay queued and are sent next launch)"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in {1..40}; do [[ -z $(running_copies) ]] && break; sleep 0.25; done
    if [[ -n $(running_copies) ]]; then
        running_copies | sed 's/^/    still running: pid /' >&2
        fail "Ambulando is still running; quit it (Ambulando > Quit) and run this again."
    fi
fi

stage="installing to $target"
# Copy first, then swap: the installed app is replaced only once a complete, verified copy exists, and it is put
# back if the swap fails.
staged=$target/.Ambulando.app.installing previous=$target/.Ambulando.app.previous
if [[ ! -e $dest && -d $previous ]]; then
    print "==> Restoring $dest left aside by an interrupted earlier install"
    mv "$previous" "$dest"
fi
rm -rf "$staged" "$previous"
copy_out=$( { ditto "$APP" "$staged" && codesign --verify --strict --deep "$staged"; } 2>&1) || {
    print -u2 -r -- "$copy_out"
    rm -rf "$staged"
    fail "could not copy the app to $target."
}
if [[ -d $dest ]]; then
    print "    replacing $dest, currently $(describe_app "$dest")"
    mv "$dest" "$previous"
fi
if ! mv "$staged" "$dest"; then
    [[ -d $previous ]] && mv "$previous" "$dest"
    rm -rf "$staged"
    fail "could not move the new app into $dest; the previous app was put back."
fi
rm -rf "$previous"
installed=$dest

stage="verifying the installed app"
installed_version=$(plist_value "$dest" CFBundleShortVersionString) || installed_version=""
installed_build=$(plist_value "$dest" CFBundleVersion) || installed_build=""
installed_id=$(plist_value "$dest" CFBundleIdentifier) || installed_id=""
if [[ $installed_version != $version || $installed_build != $build || $installed_id != $bundle_id ]]; then
    fail "$dest reports $installed_id $installed_version (build $installed_build), expected $bundle_id $version (build $build)."
fi
verify_out=$(codesign --verify --strict --deep "$dest" 2>&1) || { print -u2 -r -- "$verify_out"; fail "$dest did not verify."; }
print "==> Installed $dest: Ambulando $installed_version (build $installed_build)"

# Other copies open the version they contain (from the Dock, Spotlight or Finder). Left in place; only reported.
others=() seen=()
for candidate in /Applications/Ambulando.app $HOME/Applications/Ambulando.app \
        ${(f)"$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null || true)"}; do
    [[ -d $candidate && ${candidate:A} != ${dest:A} && ${candidate:A} != ${ROOT:A}/build/* ]] || continue
    (( ${seen[(Ie)${candidate:A}]} )) && continue
    seen+=(${candidate:A}) others+=($candidate)
done
if (( ${#others} )); then
    print "==> Other Ambulando copies on this Mac (opening one of these starts that version, not this one):"
    for other in $others; do print "    $other: $(describe_app "$other")"; done
    print "    Open $dest, and remove or replace the old copies (and their Dock icons) once you have checked it."
fi

if (( open_app )); then
    stage="opening $dest"
    open "$dest" || fail "macOS could not open $dest."
    launched=""
    for _ in {1..40}; do launched=$(running_copies); [[ -n $launched ]] && break; sleep 0.25; done
    if [[ -z $launched ]]; then
        print -u2 "warning: opened $dest, but no running Ambulando was seen within 10 seconds."
    else
        stage="checking which copy is running"
        for line in ${(f)launched}; do
            running_app=${line#* }
            if [[ ${running_app:A} == ${dest:A} ]]; then
                print "==> Running: $running_app, Ambulando $(describe_app "$running_app")"
            else
                fail "a different copy is running: $running_app, $(describe_app "$running_app"). Quit it and open $dest."
            fi
        done
    fi
fi
print "    In Ambulando, Settings > About should show Version $version and Build $build."
exit 0
