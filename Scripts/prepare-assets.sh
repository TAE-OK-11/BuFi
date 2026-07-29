#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Design/AppIcon-1024.png.base64"
DESTINATION="$ROOT_DIR/BuFi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
FONT_DESTINATION="$ROOT_DIR/BuFi/Resources/Fonts/Unbounded.ttf"
FONT_URL="https://raw.githubusercontent.com/google/fonts/8b80d4f3f73cfe02b69a6f0dc71da5a1cc574bd3/ofl/unbounded/Unbounded%5Bwght%5D.ttf"
FONT_SHA256="323b511be380c8d474ef030686b71aedde501f8d9cd46da558b7c40454372c3f"

if [ ! -f "$SOURCE" ]; then
  echo "Missing app icon source: $SOURCE" >&2
  exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"
openssl base64 -d -A -in "$SOURCE" -out "$DESTINATION"

font_is_valid() {
  [ -f "$FONT_DESTINATION" ] &&
    [ "$(shasum -a 256 "$FONT_DESTINATION" | awk '{print $1}')" = "$FONT_SHA256" ]
}

if ! font_is_valid; then
  FONT_TEMP="$(mktemp "${TMPDIR:-/tmp}/bufi-unbounded.XXXXXX")"
  trap 'rm -f "$FONT_TEMP"' EXIT HUP INT TERM
  curl --fail --location --retry 3 --silent --show-error \
    "$FONT_URL" \
    --output "$FONT_TEMP"
  if [ "$(shasum -a 256 "$FONT_TEMP" | awk '{print $1}')" != "$FONT_SHA256" ]; then
    echo "Unbounded font checksum mismatch" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$FONT_DESTINATION")"
  mv "$FONT_TEMP" "$FONT_DESTINATION"
  trap - EXIT HUP INT TERM
fi
