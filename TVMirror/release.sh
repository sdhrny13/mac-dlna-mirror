#!/bin/bash
# Builds the downloadable disk image build/release/TVMirror-<version>.dmg: a universal app
# (Apple Silicon + Intel) next to an Applications shortcut, plus its SHA-256 checksum.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ARCHS="arm64 x86_64" ./build.sh
OUT="build/release"
STAGE="$OUT/stage"
DMG="$OUT/TVMirror-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$STAGE"
ditto build/TVMirror.app "$STAGE/TVMirror.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "TVMirror $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Done: $(pwd)/$DMG"
cat "$DMG.sha256"
