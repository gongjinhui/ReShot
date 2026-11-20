#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache dist
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache Sources/ReShot/ScrollStitcher.swift Tests/Stitcher/main.swift -o dist/stitcher-tests -framework CoreGraphics
./dist/stitcher-tests | tee dist/stitcher-tests.log
