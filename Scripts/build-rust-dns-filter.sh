#!/bin/sh
set -eu

cd "$(dirname "$0")/../RustDNSFilter"

case "${PLATFORM_NAME:-iphoneos}" in
  iphoneos)
    target="aarch64-apple-ios"
    ;;
  iphonesimulator)
    case "${NATIVE_ARCH_ACTUAL:-arm64}" in
      arm64) target="aarch64-apple-ios-sim" ;;
      *) target="x86_64-apple-ios" ;;
    esac
    ;;
  *)
    printf 'Unsupported Apple platform: %s\n' "${PLATFORM_NAME:-unknown}" >&2
    exit 1
    ;;
esac

rustup target add "$target"
cargo build --locked --release --target "$target"

output_dir="${DERIVED_FILE_DIR:-build/active}"
mkdir -p "$output_dir"
cp "target/$target/release/libbufi_dns_filter.a" \
  "$output_dir/libbufi_dns_filter.a"
