#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/ReShot.app/Contents/{MacOS,Resources} .build/module-cache
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache -target "$(uname -m)-apple-macosx13.0" Sources/ReShot/*.swift -o dist/ReShot.app/Contents/MacOS/ReShot -framework AppKit -framework Vision -framework Carbon -framework ScreenCaptureKit -framework AVFoundation
cp Resources/Info.plist dist/ReShot.app/Contents/Info.plist
cp Resources/ReShot.icns dist/ReShot.app/Contents/Resources/
codesign --force --sign - dist/ReShot.app
printf 'Built %s/dist/ReShot.app\n' "$PWD"
