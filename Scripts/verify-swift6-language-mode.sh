#!/bin/sh
set -eu

xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
swift_version="$(xcrun swiftc --version | sed -n '1p')"

# SWIFT_VERSION is the language-mode selector. Swift 6.3/6.4 both use
# SWIFT_VERSION=6.0 / -swift-version 6. Verify the actual compiler release
# separately so stable Xcode 26.6 remains the Swift 6.3 baseline while the
# Xcode 27 compatibility lane is guaranteed to compile BuFi with Swift 6.4.
case "$xcode_version" in
    26.6)
        printf '%s\n' "$swift_version" \
            | grep -Eq '(Apple )?Swift version 6\.3(\.[0-9]+)?([[:space:]]|$)'
        ;;
    27.*)
        printf '%s\n' "$swift_version" \
            | grep -Eq '(Apple )?Swift version 6\.4(\.[0-9]+)?([[:space:]]|$)'
        ;;
esac

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
