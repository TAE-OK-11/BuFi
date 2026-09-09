#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUFI_BACKEND_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$BUFI_BACKEND_TEST_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    BuFi/Core/OpenSubsonicRequestEncoding.swift \
    BuFi/Core/PlaybackTimelinePolicy.swift \
    Tests/PlaybackRequestRegression.swift \
    -o "$BUFI_BACKEND_TEST_DIR/backend-regressions"
"$BUFI_BACKEND_TEST_DIR/backend-regressions"
