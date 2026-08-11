#!/bin/sh
set -eu

settings="$(
    xcodebuild \
        -project BuFi.xcodeproj \
        -scheme BuFi \
        -configuration Debug \
        -showBuildSettings
)"

printf '%s\n' "$settings" \
    | grep -Eq '^[[:space:]]*SWIFT_VERSION = 6(\.0)?[[:space:]]*$'
printf '%s\n' "$settings" \
    | grep -Eq '^[[:space:]]*SWIFT_STRICT_CONCURRENCY = complete[[:space:]]*$'
