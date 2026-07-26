#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Design/AppIcon-1024.png.base64"
DESTINATION="$ROOT_DIR/BuFi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

if [ ! -f "$SOURCE" ]; then
  echo "Missing app icon source: $SOURCE" >&2
  exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"
openssl base64 -d -A -in "$SOURCE" -out "$DESTINATION"
