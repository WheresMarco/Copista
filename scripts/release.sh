#!/bin/bash
# Builds a release of Copista and puts it on GitHub as a draft release:
#   - Copista-<version>.dmg   for people to download and drag to Applications
#   - Copista-<version>.zip   what the app's updater downloads
#   - appcast.xml             the update feed, read from the latest release
#
# Usage: scripts/release.sh 1.1.0
#        DRY_RUN=1 scripts/release.sh 1.1.0   builds everything, but skips the git checks and GitHub
#
# Before running it: add a "## 1.1.0" section to CHANGELOG.md, commit, and push. Afterwards, check
# the draft on GitHub and publish it. Copista only sees an update once the release is published.
set -euo pipefail

VERSION=${1:?"Usage: scripts/release.sh <version>, for example 1.1.0"}
REPO=WheresMarco/Copista
TAG="v$VERSION"

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT="build/release/$VERSION"
FEED="$OUT/feed"

fail() { echo "error: $*" >&2; exit 1; }

# --- Checks: a release is built from exactly what's on GitHub ---------------------------------

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version should look like 1.2.0"
if [[ -z "${DRY_RUN:-}" ]]; then
    [[ -z "$(git status --porcelain)" ]] || fail "there are uncommitted changes"
    git fetch --quiet origin
    [[ -n "$(git branch -r --contains HEAD)" ]] || fail "this commit isn't pushed yet"
    ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$TAG already exists"
    gh auth status >/dev/null 2>&1 || fail "log in with: gh auth login"
fi

# The CHANGELOG section for this version, without its heading.
NOTES=$(awk -v v="$VERSION" '
    /^## / { if (found) exit; found = ($2 == v); next }
    found' CHANGELOG.md)
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "CHANGELOG.md has no \"## $VERSION\" section"

# Sparkle compares build numbers. The commit count only ever grows.
BUILD=$(git rev-list --count HEAD)

# --- Build ------------------------------------------------------------------------------------

rm -rf "$OUT" && mkdir -p "$FEED"
echo "Building Copista $VERSION ($BUILD)…"
# Signed to run locally ("-"), without the debugging entitlement Xcode adds by default.
xcodebuild archive -quiet \
    -project Copista.xcodeproj -scheme Copista -configuration Release \
    -archivePath "$OUT/Copista.xcarchive" -derivedDataPath build/DerivedData \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

APP="$OUT/Copista.xcarchive/Products/Applications/Copista.app"
codesign --verify --deep --strict "$APP"
KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")
[[ -n "$KEY" ]] || fail "the app has no SUPublicEDKey, so it couldn't update itself"

# --- Package ----------------------------------------------------------------------------------

# For Sparkle: a zip made the way Finder makes one, keeping the framework's symlinks.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$FEED/Copista-$VERSION.zip"
printf '%s\n' "$NOTES" > "$FEED/Copista-$VERSION.md"

# For people: a disk image with Applications beside the app, to drag it onto.
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Copista.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Copista $VERSION" -srcfolder "$STAGING" -fs APFS -format ULFO "$OUT/Copista-$VERSION.dmg"
rm -rf "$STAGING"

# --- Update feed ------------------------------------------------------------------------------

# Signs the zip with the private key in the login keychain (made by Sparkle's generate_keys). macOS
# may ask to allow access to it.
BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
"$BIN/generate_appcast" --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    "$FEED"

# --- Publish as a draft -----------------------------------------------------------------------

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "Dry run: nothing was uploaded. The files are in $OUT"
    exit 0
fi

gh release create "$TAG" --repo "$REPO" --draft \
    --target "$(git rev-parse HEAD)" \
    --title "Copista $VERSION" \
    --notes "$NOTES" \
    "$OUT/Copista-$VERSION.dmg" "$FEED/Copista-$VERSION.zip" "$FEED/appcast.xml"

echo
echo "Draft release $TAG is on GitHub. Check it, then publish it:"
echo "  https://github.com/$REPO/releases"
