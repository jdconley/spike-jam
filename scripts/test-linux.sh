#!/usr/bin/env bash
# Runs the SpikeCore tests on Linux in Docker's official Swift image.
# The tag matches the local toolchain's major.minor (Swift 6.4).
# The build goes to a scratch path inside the container so it never
# clobbers the macOS .build directory in the mounted package.
set -euo pipefail

SWIFT_TAG="6.4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker run --rm \
  -v "$ROOT/Packages/SpikeCore":/pkg \
  -w /pkg \
  "swift:$SWIFT_TAG" \
  swift test --scratch-path /tmp/spikecore-build "$@"
