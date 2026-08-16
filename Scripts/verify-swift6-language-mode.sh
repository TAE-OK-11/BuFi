#!/bin/sh
set -eu

xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
swift_version="$(xcrun swiftc --version | sed -n '1p')"

# SWIFT_VERSION remains the Swift 6 language-mode selector (6.0). The actual
# compiler release is verified independently. The unified CI lane intentionally
# uses Xcode 27 / Swift 6.4 while keeping the deployment target at iOS 17.
case "$xcode_version" in
    27.*) ;;
    *)
        printf 'Expected Xcode 27.x, found %s\n' "$xcode_version" >&2
        exit 1
        ;;
esac
printf '%s\n' "$swift_version" \
    | grep -Eq '(Apple )?Swift version 6\.4(\.[0-9]+)?([[:space:]]|$)'

printf 'Xcode %s / %s\n' "$xcode_version" "$swift_version"

for target in BuFi; do
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
        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*OTHER_SWIFT_FLAGS = .*NonisolatedNonsendingByDefault'
        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = 17\.0[[:space:]]*$'

        if [ "$configuration" = "Debug" ]; then
            printf '%s\n' "$settings" \
                | grep -Eq '^[[:space:]]*OTHER_SWIFT_FLAGS = .*enable-actor-data-race-checks'
        else
            printf '%s\n' "$settings" \
                | grep -Eq '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = -O[[:space:]]*$'
            printf '%s\n' "$settings" \
                | grep -Eq '^[[:space:]]*SWIFT_COMPILATION_MODE = wholemodule[[:space:]]*$'
            printf '%s\n' "$settings" \
                | grep -Eq '^[[:space:]]*LLVM_LTO = YES[[:space:]]*$'
            printf '%s\n' "$settings" \
                | grep -Eq '^[[:space:]]*DEAD_CODE_STRIPPING = YES[[:space:]]*$'
        fi
    done
done
