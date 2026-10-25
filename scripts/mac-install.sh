#!/bin/zsh
# Builds the native Mac app (Release, Apple Silicon + Intel), signs it, installs it and optionally packages a ZIP.
#
#   scripts/mac-install.sh                 build, sign, install to /Applications (or ~/Applications), open it
#   scripts/mac-install.sh --package       also write dist/Ambulando-mac-<version>-<build>.zip and its SHA-256
#   scripts/mac-install.sh --no-install    build (and package) only
#   scripts/mac-install.sh --no-open       install without opening the app
#
# Signing: AMBULANDO_SIGN_IDENTITY if set, otherwise the first "Developer ID Application", then "Apple Development"
# identity in your keychain, otherwise ad-hoc. Only the identity's name is read; nothing is exported. A stable identity
# matters: macOS lets the app that created a Keychain item read it without asking, and "the same app" means the same
# signer. With ad-hoc signing every rebuild is a new signer, so after an update macOS asks for your login password once
# (choose Always Allow). The app is not notarized by this script.
#
# Your data is kept across reinstalls: it lives in the app's sandbox container
# (~/Library/Containers/studio.otherstuff.ambulando.mac), not inside Ambulando.app.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

package=0 install=1 open_app=1
for arg in "$@"; do
    case $arg in
        --package) package=1 ;;
        --no-install) install=0 ;;
        --no-open) open_app=0 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) print -u2 "Unknown option: $arg"; exit 2 ;;
    esac
done

[[ $(uname -s) == Darwin ]] || { print -u2 "macOS is required."; exit 1 }
xcodebuild -version >/dev/null 2>&1 || { print -u2 "Xcode is required (xcode-select -s /Applications/Xcode.app)."; exit 1 }

DERIVED=$ROOT/build/mac-release
APP=$DERIVED/Build/Products/Release/Ambulando.app
LOG=$ROOT/build/mac-release.log
mkdir -p "$ROOT/build"

print "==> Building Ambulando for Mac (Release, arm64 + x86_64); log: $LOG"
if ! xcodebuild -skipPackagePluginValidation -project Ambulando.xcodeproj -scheme AmbulandoMac -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -20 >&2
    print -u2 "Build failed; see $LOG"
    exit 1
fi

identity=${AMBULANDO_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
    for kind in "Developer ID Application" "Apple Development"; do
        identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n "s/.*\"\\($kind:[^\"]*\\)\".*/\\1/p" | head -1)
        [[ -n $identity ]] && break
    done
fi
[[ -n $identity ]] || identity=-
print "==> Signing with: ${identity/#-/ad-hoc (no stable identity found)}"
# Developer ID signatures carry Apple's secure timestamp (needed for notarization); others do not need one.
timestamp=--timestamp=none
[[ $identity == "Developer ID Application"* ]] && timestamp=--timestamp
codesign --force --options runtime $timestamp --entitlements Config/AmbulandoMac.entitlements --sign "$identity" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
archs=$(lipo -archs "$APP/Contents/MacOS/Ambulando")
print "==> Built Ambulando $version ($build), architectures: $archs"

if (( package )); then
    mkdir -p dist
    zip=dist/Ambulando-mac-$version-$build.zip
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"
    shasum -a 256 "$zip" | tee "$zip.sha256"
fi

if (( install )); then
    target=/Applications
    [[ -w $target ]] || { target=$HOME/Applications; mkdir -p "$target" }
    dest=$target/Ambulando.app
    running() { pgrep -f "$dest/Contents/MacOS/Ambulando" >/dev/null }
    if running; then
        print "==> Quitting the running Ambulando (unsent messages and changes stay queued and are sent next launch)"
        osascript -e 'tell application id "studio.otherstuff.ambulando.mac" to quit' >/dev/null 2>&1 || true
        for _ in {1..40}; do running || break; sleep 0.25; done
        running && { print -u2 "Ambulando is still running; quit it and run this again."; exit 1 }
    fi
    # Copy first, then swap: the installed app is replaced only once a complete, verified copy exists, and it is put
    # back if the swap fails.
    staged=$target/.Ambulando.app.installing previous=$target/.Ambulando.app.previous
    rm -rf "$staged" "$previous"
    if ! ditto "$APP" "$staged" || ! codesign --verify --strict --deep "$staged"; then
        rm -rf "$staged"
        print -u2 "Could not copy the app to $target; the installed app (if any) is unchanged."
        exit 1
    fi
    [[ -d $dest ]] && mv "$dest" "$previous"
    if ! mv "$staged" "$dest"; then
        [[ -d $previous ]] && mv "$previous" "$dest"
        rm -rf "$staged"
        print -u2 "Could not install to $dest; the previous app was restored."
        exit 1
    fi
    rm -rf "$previous"
    print "==> Installed $dest"
    if (( open_app )); then open "$dest"; fi
fi
exit 0
