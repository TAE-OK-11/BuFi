#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

project_yml="project.yml"
lock_path="Package.resolved"
check_upstream=0

for arg in "$@"; do
    case "$arg" in
        --check-upstream) check_upstream=1 ;;
        -h|--help)
            printf 'Usage: %s [--check-upstream]\n' "$(basename "$0")" >&2
            printf '  Verifies project.yml exactVersion pins match Package.resolved.\n' >&2
            printf '  With --check-upstream, also requires gh and network access to\n' >&2
            printf '  confirm each linked package is on its latest GitHub release.\n' >&2
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$arg" >&2
            exit 1
            ;;
    esac
done

test -f "$project_yml"
test -f "$lock_path"
command -v jq >/dev/null

project_version() {
    package="$1"
    awk -v package="$package" '
        $0 ~ "^  " package ":$" { found=1; next }
        found && /exactVersion:/ {
            sub(/.*exactVersion:[[:space:]]*/, "", $0)
            gsub(/"/, "", $0)
            print $0
            exit
        }
        found && /^  [A-Za-z]/ { exit }
    ' "$project_yml"
}

resolved_version() {
    identity="$1"
    jq -r --arg id "$identity" '
        .pins[]
        | select(.identity == $id)
        | .state.version
    ' "$lock_path"
}

resolved_revision() {
    identity="$1"
    jq -r --arg id "$identity" '
        .pins[]
        | select(.identity == $id)
        | .state.revision
    ' "$lock_path"
}

verify_pin() {
    yml_package="$1"
    resolved_identity="$2"
    yml_version="$(project_version "$yml_package")"
    lock_version="$(resolved_version "$resolved_identity")"

    if [ -z "$yml_version" ]; then
        printf 'Missing exactVersion for %s in %s\n' \
            "$yml_package" "$project_yml" >&2
        exit 1
    fi
    if [ -z "$lock_version" ] || [ "$lock_version" = "null" ]; then
        printf 'Missing pin for %s in %s\n' \
            "$resolved_identity" "$lock_path" >&2
        exit 1
    fi
    if [ "$yml_version" != "$lock_version" ]; then
        printf '%s version mismatch: %s=%s, %s=%s\n' \
            "$yml_package" "$project_yml" "$yml_version" \
            "$lock_path" "$lock_version" >&2
        exit 1
    fi

    printf 'Pinned %s %s (%s)\n' \
        "$yml_package" "$yml_version" \
        "$(resolved_revision "$resolved_identity" | cut -c1-12)"
}

verify_pin SwiftSonic swiftsonic
verify_pin Nuke nuke
verify_pin Zstandard zstd
verify_pin GRDB grdb.swift

minimum_xcodegen="$(awk -F'"' '/minimumXcodeGenVersion:/ { print $2; exit }' "$project_yml")"
if [ -z "$minimum_xcodegen" ]; then
    printf 'Missing minimumXcodeGenVersion in %s\n' "$project_yml" >&2
    exit 1
fi
printf 'Minimum XcodeGen %s\n' "$minimum_xcodegen"

if [ "$check_upstream" -eq 0 ]; then
    exit 0
fi

command -v gh >/dev/null

normalize_release_version() {
    printf '%s' "$1" \
        | sed 's/^v//;s/^Nuke //;s/^Zstandard //'
}

latest_release_version() {
    repo="$1"
    tag="$(gh release list -R "$repo" --limit 1 --json tagName \
        | jq -r '.[0].tagName')"
    normalize_release_version "$tag"
}

verify_latest() {
    yml_package="$1"
    resolved_identity="$2"
    repo="$3"
    pinned="$(project_version "$yml_package")"
    latest="$(latest_release_version "$repo")"

    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        printf 'Could not resolve latest release for %s\n' "$repo" >&2
        exit 1
    fi
    if [ "$pinned" != "$latest" ]; then
        printf '%s is pinned at %s but %s latest is %s\n' \
            "$yml_package" "$pinned" "$repo" "$latest" >&2
        exit 1
    fi
    printf 'Latest %s %s\n' "$yml_package" "$latest"
}

verify_latest SwiftSonic swiftsonic CassetteLab/swiftsonic
verify_latest Nuke nuke kean/Nuke
verify_latest Zstandard zstd facebook/zstd
verify_latest GRDB grdb.swift groue/GRDB.swift

xcodegen_latest="$(gh release list -R yonaskolb/XcodeGen --limit 1 --json tagName \
    | jq -r '.[0].tagName' | sed 's/^v//')"
if [ "$minimum_xcodegen" != "$xcodegen_latest" ]; then
    printf 'minimumXcodeGenVersion is %s but XcodeGen latest is %s\n' \
        "$minimum_xcodegen" "$xcodegen_latest" >&2
    exit 1
fi
printf 'Latest XcodeGen %s\n' "$xcodegen_latest"
