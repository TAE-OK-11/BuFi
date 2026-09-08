#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUFI_SEARCH_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$BUFI_SEARCH_TEST_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    BuFi/Core/ServerAuthMethod.swift \
    BuFi/Core/Models.swift \
    BuFi/Core/LocalLibrarySearch.swift \
    Tests/LocalLibrarySearchRegression.swift \
    -o "$BUFI_SEARCH_TEST_DIR/search-regressions"
"$BUFI_SEARCH_TEST_DIR/search-regressions"
