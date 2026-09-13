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

# The directory's rust-toolchain.toml is the single source of truth. Avoid a
# second hard-coded version here that can silently diverge from Cargo and CI.
rustup target add "$target"
cargo build --locked --release --target "$target"

# Xcode gives each target/configuration an architecture-specific derived-file
# directory. Publishing there prevents a simulator archive from being reused
# accidentally for a device link and lets dependency analysis skip this phase
# when neither the Rust inputs nor toolchain declaration changed.
output_dir="${DERIVED_FILE_DIR:-build/active}"
mkdir -p "$output_dir"
cp "target/$target/release/libbufi_tunnel_engine.a" \
  "$output_dir/libbufi_tunnel_engine.a"
