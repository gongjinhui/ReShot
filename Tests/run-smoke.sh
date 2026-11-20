#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
dist/ReShot.app/Contents/MacOS/ReShot --stitch-test | tee dist/stitcher-tests.log
dist/ReShot.app/Contents/MacOS/ReShot --preview-test | tee dist/preview-test.log
dist/ReShot.app/Contents/MacOS/ReShot --selection-test
dist/ReShot.app/Contents/MacOS/ReShot --storage-test
dist/ReShot.app/Contents/MacOS/ReShot --annotation-test
dist/ReShot.app/Contents/MacOS/ReShot --ocr-test
codesign --verify --deep --strict dist/ReShot.app
