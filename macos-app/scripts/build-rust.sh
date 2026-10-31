#!/usr/bin/env bash
# The Mac project's Rust pre-build phase: the one script in
# ios-app/scripts/build-rust.sh builds every Apple slice, and picks the
# macOS one when Xcode sets PLATFORM_NAME=macosx (a Mac build). By hand:
#
#   PLATFORM_NAME=macosx ARCHS="arm64" macos-app/scripts/build-rust.sh
#
# One-time setup: rustup target add aarch64-apple-darwin (x86_64-apple-darwin
# too for a universal build; macOS 27 itself is Apple Silicon only)
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
exec "$ROOT/ios-app/scripts/build-rust.sh"
