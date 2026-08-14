#!/bin/sh
set -eu

xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
swift_version="$(xcrun swiftc --version | sed -n '1p')"

# SWIFT_VERSION is the language-mode selector. Swift 6.3 still uses
# SWIFT_VERSION=6.0 / -swift-version 6. Xcode 26.6 is the stable CI toolchain
# that provides Swift 6.3.x, so verify the compiler release separately.
if [ "$xcode_version" = "26.6" ]; then
    printf '%s\n' "$swift_version" \
        | grep -Eq 'Swift version 6\.3(\.[0-9]+)?([[:space:]]|$)'
fi

printf 'Xcode %s / %s\n' "$xcode_version" "$swift_version"

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
