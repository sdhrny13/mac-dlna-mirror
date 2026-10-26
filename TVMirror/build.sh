#!/bin/bash
# Builds TVMirror.app. Only the Command Line Tools are needed (xcode-select --install), not Xcode.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/TVMirror.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p build/obj
# Objective-C shim for the private virtual monitor API ("Second display" mode)
clang -c -fobjc-arc -O2 -target arm64-apple-macos14.0 Sources/VirtualDisplayShim.m -o build/obj/VirtualDisplayShim.o
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-name TVMirror \
  -import-objc-header Sources/VirtualDisplayShim.h \
  Sources/*.swift build/obj/VirtualDisplayShim.o -o "$APP/Contents/MacOS/TVMirror"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # localized permission prompts
# By default an ad-hoc signature is tied to the build hash (cdhash), and after every rebuild macOS
# forgets the Screen Recording permission. A requirement based on the identifier keeps it across builds.
codesign --force --sign - --identifier local.tvmirror.app \
  -r '=designated => identifier "local.tvmirror.app"' "$APP"
echo "Done: $(pwd)/$APP"
