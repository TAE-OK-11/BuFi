#!/bin/sh
set -eu

for target in BuFi BuFiTests; do
    for configuration in Debug Release; do
        settings="$(
            xcodebuild \
                -project BuFi.xcodeproj \
                -target "$target" \
                -configuration "$configuration" \
                -showBuildSettings
        )"

        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*SWIFT_VERSION = 6(\.0)?[[:space:]]*$'
        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*SWIFT_STRICT_CONCURRENCY = complete[[:space:]]*$'
    done
done
