#!/usr/bin/env bash
# Runs the SpikeCore and SpikeNet tests on Linux in Docker's official Swift image.
# The tag matches the local toolchain's major.minor (Swift 6.4).
# The builds go to scratch paths inside the container so they never
# clobber the macOS .build directories in the mounted packages.
#
# The tests run in release with testing enabled: the simulation suites play
# hundreds of matches, and optimized they run about ten times faster, with the
# same assertions (SpikeCore and SpikeNet use no assert(), only checks the
# tests make and preconditions, which release keeps).
#
#   scripts/test-linux.sh                 both packages
#   scripts/test-linux.sh SpikeCore       one package
#   scripts/test-linux.sh SpikeNet --filter Prediction   extra arguments go to swift test
set -euo pipefail

SWIFT_TAG="6.4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

packages=(SpikeCore SpikeNet)
if [ $# -gt 0 ] && [ -f "$ROOT/Packages/$1/Package.swift" ]; then
  packages=("$1")
  shift
fi

# Each package builds in the container's own scratch path; SpikeNet's path
# dependency on ../SpikeCore resolves inside the mounted Packages directory.
script=""
for p in "${packages[@]}"; do
  lower="$(echo "$p" | tr '[:upper:]' '[:lower:]')"
  script+="echo '== $p'; swift test --package-path /pkgs/$p --scratch-path /tmp/$lower-build -c release -Xswiftc -enable-testing $* || exit 1; "
done

docker run --rm \
  -v "$ROOT/Packages":/pkgs \
  "swift:$SWIFT_TAG" \
  bash -c "$script"
