#!/bin/sh
set -eu

project_path="${1:-BuFi.xcodeproj}"
lock_path="Package.resolved"

test -d "$project_path"
test -f "$lock_path"

destination="$project_path/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$destination"
cp "$lock_path" "$destination/Package.resolved"
