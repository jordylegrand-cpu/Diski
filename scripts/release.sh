#!/bin/bash
# Builds Diski, signs it with Developer ID, notarizes and staples it, and
# publishes it as the latest GitHub release, which Diski's in-app updater
# installs. The tag's version must match MARKETING_VERSION, and HEAD must be
# committed and pushed to origin/main.
#
# Usage: scripts/release.sh v0.1.3-alpha [whats-new.md]
#   whats-new.md: optional Markdown list, shown under "What's new".
# Environment: SIGNING_IDENTITY, DEVELOPMENT_TEAM, NOTARY_PROFILE (a
# notarytool keychain profile) and GITHUB_REPOSITORY override the defaults.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh vX.Y.Z-alpha [whats-new.md]}"
WHATS_NEW="${2:-}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Jordy Spruit (NARHG44L48)}"
TEAM="${DEVELOPMENT_TEAM:-NARHG44L48}"
PROFILE="${NOTARY_PROFILE:-Droppy-Notarize}"
REPO="${GITHUB_REPOSITORY:-jordylegrand-cpu/Diski}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "release: $*" >&2; exit 1; }

cd "$ROOT"
[ -z "$WHATS_NEW" ] || [ -f "$WHATS_NEW" ] || fail "no such file: $WHATS_NEW"
git diff --quiet && git diff --cached --quiet || fail "commit your changes first"
git fetch -q origin main
git merge-base --is-ancestor HEAD origin/main || fail "push HEAD to origin/main first"
COMMIT="$(git rev-parse HEAD)"

MARKETING="$(xcodebuild -project Diski.xcodeproj -scheme Diski -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
BASE="${VERSION#v}"
[ "${BASE%%-*}" = "$MARKETING" ] || fail "$VERSION does not match MARKETING_VERSION $MARKETING"

echo "Building $VERSION ($COMMIT)…"
xcodebuild -project Diski.xcodeproj -scheme Diski -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  build > "$WORK/build.log" 2>&1 || { grep -E "error:" "$WORK/build.log" >&2; fail "build failed"; }
APP="$WORK/build/Build/Products/Release/Diski.app"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
grep -q "^TeamIdentifier=$TEAM$" <<< "$SIGNATURE" && grep -q "^Authority=Developer ID Application" <<< "$SIGNATURE" \
  || { echo "$SIGNATURE" >&2; fail "Diski.app is not signed with Developer ID by team $TEAM"; }

echo "Notarizing…"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait \
  --output-format json > "$WORK/notary.json" || true
SUBMISSION="$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || true)"
if [ "$STATUS" != "Accepted" ]; then
  [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
  fail "notarization ${STATUS:-failed}"
fi
xcrun stapler staple "$APP" > /dev/null
xcrun stapler validate "$APP" > /dev/null
spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the notarized app"

ZIP="$WORK/Diski-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SUM="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# The updater reads the asset name (Diski-<tag>.zip) and the SHA-256 line.
{
  echo "<p align=\"center\"><img src=\"https://raw.githubusercontent.com/$REPO/$COMMIT/docs/icon-midnight.png\" width=\"128\" alt=\"Diski\"></p>"
  echo
  echo "**Diski $VERSION** — an alpha of the fast, native Finder alternative for macOS 26 and later, signed with Developer ID and notarized by Apple."
  echo
  echo "- Four views (icons, list, columns, gallery), Finder's sidebar and native preview pane"
  echo "- Instant APFS clones, parallel copies, Finder's Copy window with pause and stop"
  echo "- Native Get Info, View Options, conflict alerts, Go to Folder and Connect to Server"
  echo "- Dual pane, instant filter, cut & paste, folder sizes, Recents and more — see the README"
  if [ -n "$WHATS_NEW" ]; then
    echo
    echo "### What's new in ${BASE%%-*}"
    cat "$WHATS_NEW"
  fi
  echo
  echo "### Install"
  echo "1. Download **Diski-$VERSION.zip** below, unzip it and move **Diski.app** to Applications."
  echo "2. Open Diski. For the Trash and other protected folders, give it Full Disk Access in System Settings › Privacy & Security."
  echo "3. From then on Diski updates itself (Diski › Check for Updates…)."
  echo
  echo "SHA-256: \`$SUM\`"
  echo
  echo "This is an alpha: expect rough edges and please report issues."
} > "$WORK/notes.md"

echo "Publishing…"
gh release create "$VERSION" "$ZIP" --repo "$REPO" --target "$COMMIT" \
  --title "Diski $VERSION" --notes-file "$WORK/notes.md" --latest
echo "Released $VERSION: https://github.com/$REPO/releases/tag/$VERSION"
