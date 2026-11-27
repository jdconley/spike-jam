#!/bin/bash
# Builds the app (Debug, signed for development) and installs and launches it on a paired iPhone.
#
#   scripts/device.sh                    the first available paired iPhone
#   scripts/device.sh <UDID or name>     that device
#   scripts/device.sh --demo assist      pass launch arguments after the device (or alone):
#                                        -demo autoplay | solo | assist
#   scripts/device.sh --dry-run          print the commands, run nothing
#
# The phone must be unlocked, paired with this Mac and in Developer Mode. Signing is automatic
# (team B222J9J7B8) with Xcode's signed-in account.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
DEVICE=""
LAUNCH_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --demo) shift; LAUNCH_ARGS+=(-demo "${1:?--demo takes autoplay, solo or assist}") ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) DEVICE="$1" ;;
  esac
  shift
done

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  [ "$DRY_RUN" -eq 1 ] || "$@"
}

if [ -z "$DEVICE" ]; then
  # The first physical iPhone devicectl lists as available (paired).
  json="$(mktemp)"
  trap 'rm -f "$json"' EXIT
  xcrun devicectl list devices --json-output "$json" >/dev/null
  DEVICE="$(python3 - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    # "unavailable" is a phone out of reach now; "disconnected" connects on demand.
    if hw.get("reality") == "physical" and hw.get("deviceType") == "iPhone" and conn.get("pairingState") == "paired" \
            and conn.get("tunnelState") != "unavailable":
        print(d["hardwareProperties"]["udid"])
        break
PY
)"
  if [ -z "$DEVICE" ]; then
    echo "no paired iPhone is available: connect and unlock it (xcrun devicectl list devices)" >&2
    exit 1
  fi
fi
echo "device: $DEVICE"

DERIVED=build/device
APP="$DERIVED/Build/Products/Debug-iphoneos/SpikeJam.app"

run scripts/bootstrap.sh
run xcodebuild build -project SpikeJam.xcodeproj -scheme SpikeJam -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet
run xcrun devicectl device install app --device "$DEVICE" "$APP"
run xcrun devicectl device process launch --device "$DEVICE" --terminate-existing com.conleychaos.spikejam \
  ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
