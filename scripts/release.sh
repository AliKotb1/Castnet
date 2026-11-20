#!/bin/bash
# Builds Castnet and publishes a GitHub release for the version in CastnetCore/Util.swift.
#   scripts/release.sh            build, check, and publish tag v<version>
#   DRY_RUN=1 scripts/release.sh  build everything into dist/release, publish nothing
#   SKIP_BUILD=1 scripts/release.sh  publish the DMG already built (e.g. after testing a DRY_RUN)
# Needs: vendor/ (scripts/fetch-vendor.sh) and the GitHub CLI logged in to the repo owner.
# Optional, passed through to the build: SIGN_IDENTITY, NOTARY_PROFILE, CHROME_EXTENSION_IDS, SIGNED_XPI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-AliKotb1/Castnet}"
VERSION="$(sed -n 's/^public let castnetVersion = "\(.*\)"/\1/p' "$ROOT/app/Sources/CastnetCore/Util.swift")"
TAG="v$VERSION"
OUT="$ROOT/dist/release"

for f in app/Sources/castnet-host/main.swift extension/manifest.json; do
  grep -q "$VERSION" "$ROOT/$f" || { echo "Version $VERSION isn't set in $f" >&2; exit 1; }
done
grep -q "^## \[$VERSION\]" "$ROOT/CHANGELOG.md" || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }

# Installed copies check this file (from the newest release) once a day: "Update available".
export CASTNET_UPDATE_URL="https://github.com/$REPO/releases/latest/download/castnet-update.json"
if [ -z "${SKIP_BUILD:-}" ]; then
  "$ROOT/scripts/make-dmg.sh"
else
  FEED_IN_APP="$(/usr/libexec/PlistBuddy -c 'Print :CastnetUpdateURL' "$ROOT/dist/Castnet.app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$FEED_IN_APP" = "$CASTNET_UPDATE_URL" ] || { echo "dist/Castnet.app wasn't built for release (no update feed): run without SKIP_BUILD" >&2; exit 1; }
  [ -f "$ROOT/dist/Castnet-$VERSION.dmg" ] || { echo "dist/Castnet-$VERSION.dmg is missing" >&2; exit 1; }
fi

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$ROOT/dist/Castnet-$VERSION.dmg" "$OUT/"
DMG_SHA="$(shasum -a 256 "$OUT/Castnet-$VERSION.dmg" | cut -d' ' -f1)"

# Every version since the last published release, newest first (versions in between were never
# released on their own, so their changes belong in these notes).
PREV="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null | sed 's/^v//')"
CHANGES="$ROOT/dist/release-changes.md"
awk -v v="$VERSION" -v prev="$PREV" '
  /^## \[/ { split($0, a, /[][]/); ver = a[2]
             if (ver == v) on = 1
             if (prev != "" && ver == prev) exit
             if (on) { print (ver == v ? "## What’s new in " ver : "## " ver " (included)"); next } }
  on && !/^\[.*\]: http/ { sub(/^### /, "#### "); print }' "$ROOT/CHANGELOG.md" > "$CHANGES"

# Installed copies read this: they offer the update, download it, check the SHA-256, and install it.
python3 "$ROOT/scripts/update-feed.py" "$VERSION" "https://github.com/$REPO/releases/download/$TAG/Castnet-$VERSION.dmg" \
  "$DMG_SHA" "$CHANGES" > "$OUT/castnet-update.json"
# FFmpeg's exact source, as its license (LGPL) asks of anyone shipping the binaries.
FFMPEG_SRC="$(ls "$ROOT"/vendor/src/ffmpeg-*.tar.xz 2>/dev/null | head -1)"
[ -n "$FFMPEG_SRC" ] || { echo "vendor/src/ffmpeg-*.tar.xz is missing: run scripts/fetch-vendor.sh" >&2; exit 1; }
cp "$FFMPEG_SRC" "$OUT/"
(cd "$OUT" && shasum -a 256 Castnet-*.dmg ffmpeg-*.tar.xz castnet-update.json > SHA256SUMS.txt)

# Release notes: install steps, then what changed.
NOTES="$ROOT/dist/release-notes.md"
{
  echo "## Install"
  echo
  echo "1. Download **Castnet-$VERSION.dmg** below, open it and drag **Castnet** into **Applications**."
  echo "2. Open Castnet. It finds the browsers on your Mac and shows how to add the extension to each one."
  if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo
    echo "> **First launch:** this build isn't signed with an Apple Developer ID yet, so macOS says it can't verify the developer. Click **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway** next to Castnet. You only do this once."
  fi
  echo
  echo "Already have Castnet 1.5.5 or later? It offers this update itself: **Download & Install** in the window that appears (or *Check for Updates…* in the Castnet menu). Your downloads, settings and files stay as they are."
  echo
  echo "Requires macOS 13 or later; runs natively on Apple Silicon and Intel. Everything it needs is inside the app."
  echo
  echo "SHA-256 of the DMG: \`$DMG_SHA\` (all files: SHA256SUMS.txt)"
  echo
  cat "$CHANGES"
  echo
  echo "---"
  echo "\`$(basename "$FFMPEG_SRC")\` is the unmodified FFmpeg source used for the bundled ffmpeg (LGPL 2.1+); see THIRD_PARTY_NOTICES.md."
} > "$NOTES"

echo "==> release files in $OUT:"; ls -la "$OUT"
if [ -n "${DRY_RUN:-}" ]; then echo "DRY_RUN: not publishing. Notes: $NOTES"; exit 0; fi
gh release create "$TAG" --repo "$REPO" --title "Castnet $VERSION" --notes-file "$NOTES" --target main "$OUT"/*
echo "==> published https://github.com/$REPO/releases/tag/$TAG"
