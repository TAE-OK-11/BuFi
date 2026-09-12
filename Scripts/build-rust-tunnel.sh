#!/bin/sh
set -eu

cd "$(dirname "$0")/../RustTunnel"

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

rustup target add --toolchain 1.95.0 "$target"
cargo +1.95.0 build --locked --release --target "$target"
mkdir -p build/active
cp "target/$target/release/libbufi_tunnel_engine.a" build/active/libbufi_tunnel_engine.a
