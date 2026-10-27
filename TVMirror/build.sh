#!/bin/bash
# Builds TVMirror.app. Only the Command Line Tools are needed (xcode-select --install), not Xcode.
# ARCHS="arm64 x86_64" ./build.sh builds a universal app (Apple Silicon + Intel), as release.sh does.
set -euo pipefail
cd "$(dirname "$0")"
ARCHS="${ARCHS:-arm64}"
APP="build/TVMirror.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
slices=()
for arch in $ARCHS; do
  obj="build/obj/$arch"
  mkdir -p "$obj"
  # Objective-C shim for the private virtual monitor API ("Second display" mode)
  clang -c -fobjc-arc -O2 -target "$arch-apple-macos14.0" Sources/VirtualDisplayShim.m -o "$obj/VirtualDisplayShim.o"
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -module-name TVMirror \
    -import-objc-header Sources/VirtualDisplayShim.h \
    Sources/*.swift "$obj/VirtualDisplayShim.o" -o "$obj/TVMirror"
  slices+=("$obj/TVMirror")
done
if [ ${#slices[@]} -eq 1 ]; then
  cp "${slices[0]}" "$APP/Contents/MacOS/TVMirror"
else
  lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/TVMirror"
fi
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # localized permission prompts
# By default an ad-hoc signature is tied to the build hash (cdhash), and after every rebuild macOS
# forgets the Screen Recording permission. A requirement based on the identifier keeps it across builds.
codesign --force --sign - --identifier local.tvmirror.app \
  -r '=designated => identifier "local.tvmirror.app"' "$APP"
echo "Done: $(pwd)/$APP"
