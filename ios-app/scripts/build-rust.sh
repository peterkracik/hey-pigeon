#!/usr/bin/env bash
# Build the Rust core for iOS and wrap it as a Swift package:
#   desktop-app/crates/ffi  ──cargo──►  libheypigeon_ffi.a (device + simulator)
#                           ──uniffi──► HeyPigeonCore.swift + C header + modulemap
#                           ──xcodebuild──► HeyPigeonCoreFFI.xcframework
# Runs as an Xcode pre-build phase and by hand. Idempotent; incremental via cargo.
#
# One-time setup:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CARGO_DIR="$ROOT/desktop-app"
PKG_DIR="$ROOT/ios-app/HeyPigeonCore"
PROFILE="${RUST_PROFILE:-release}"
CRATE=heypigeon-ffi
LIB=libheypigeon_ffi.a

# Xcode strips PATH down; cargo lives in ~/.cargo/bin for rustup installs.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cargo >/dev/null || { echo "error: cargo not found — install Rust via https://rustup.rs" >&2; exit 1; }

case "$PROFILE" in
  release) CARGO_FLAGS=(--release) ;;
  *) CARGO_FLAGS=() ;;
esac

cd "$CARGO_DIR"

# Only build what Xcode is about to link, when invoked from Xcode.
DEVICE_TARGETS=(aarch64-apple-ios)
SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)
if [[ "${PLATFORM_NAME:-}" == "iphoneos" ]]; then
  SIM_TARGETS=()
elif [[ "${PLATFORM_NAME:-}" == "iphonesimulator" ]]; then
  DEVICE_TARGETS=()
  case "${ARCHS:-arm64}" in
    *x86_64*) [[ "${ARCHS}" == *arm64* ]] || SIM_TARGETS=(x86_64-apple-ios) ;;
    *) SIM_TARGETS=(aarch64-apple-ios-sim) ;;
  esac
fi

for t in "${DEVICE_TARGETS[@]}" "${SIM_TARGETS[@]}"; do
  echo "▸ cargo build -p $CRATE --target $t ($PROFILE)"
  cargo build -p "$CRATE" --target "$t" "${CARGO_FLAGS[@]}"
done

# Bindings come from the host build's dylib: same metadata, no cross-tools needed.
echo "▸ cargo build -p $CRATE (host, for uniffi metadata)"
cargo build -p "$CRATE" "${CARGO_FLAGS[@]}"
HOST_LIB="$CARGO_DIR/target/$PROFILE/libheypigeon_ffi.dylib"

GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
echo "▸ uniffi-bindgen generate (swift)"
cargo run -q -p "$CRATE" --features bindgen --bin uniffi-bindgen -- \
  generate --library "$HOST_LIB" --language swift --out-dir "$GEN"

mkdir -p "$PKG_DIR/Sources/HeyPigeonCore" "$GEN/include"
cp "$GEN/HeyPigeonCore.swift" "$PKG_DIR/Sources/HeyPigeonCore/HeyPigeonCore.swift"
cp "$GEN/HeyPigeonCoreFFI.h" "$GEN/include/"
cp "$GEN/HeyPigeonCoreFFI.modulemap" "$GEN/include/module.modulemap"

# One fat simulator library when both simulator slices were built.
XC_ARGS=()
if (( ${#DEVICE_TARGETS[@]} )); then
  XC_ARGS+=(-library "$CARGO_DIR/target/aarch64-apple-ios/$PROFILE/$LIB" -headers "$GEN/include")
fi
if (( ${#SIM_TARGETS[@]} )); then
  if (( ${#SIM_TARGETS[@]} > 1 )); then
    mkdir -p "$GEN/sim"
    lipo -create \
      "$CARGO_DIR/target/aarch64-apple-ios-sim/$PROFILE/$LIB" \
      "$CARGO_DIR/target/x86_64-apple-ios/$PROFILE/$LIB" \
      -output "$GEN/sim/$LIB"
    XC_ARGS+=(-library "$GEN/sim/$LIB" -headers "$GEN/include")
  else
    XC_ARGS+=(-library "$CARGO_DIR/target/${SIM_TARGETS[0]}/$PROFILE/$LIB" -headers "$GEN/include")
  fi
fi

echo "▸ xcodebuild -create-xcframework"
rm -rf "$PKG_DIR/HeyPigeonCoreFFI.xcframework"
xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$PKG_DIR/HeyPigeonCoreFFI.xcframework" >/dev/null
echo "✓ $PKG_DIR/HeyPigeonCoreFFI.xcframework"
