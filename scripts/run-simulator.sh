#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# > 1 )); then
    echo "Usage: bash scripts/run-simulator.sh [simulator-UUID]" >&2
    exit 2
fi
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bash scripts/run-simulator.sh [simulator-UUID]"
    exit 0
fi
simulator_id="${1:-$(python3 scripts/select-simulator.py)}"
simulator_state="$(python3 - "$simulator_id" <<'PY'
import json
import re
import subprocess
import sys

catalog = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True))
for runtime in catalog["runtimes"]:
    if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
        continue
    version = tuple(int(part) for part in re.findall(r"\d+", runtime["version"]))
    if version < (17,):
        continue
    for device in catalog["devices"].get(runtime["identifier"], []):
        if device["udid"] == sys.argv[1] and device.get("isAvailable"):
            if not device.get("deviceTypeIdentifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
                sys.exit("Choose an iPhone simulator for this play check.")
            print(device["state"])
            sys.exit(0)
sys.exit("Choose an available iPhone simulator with iOS 17 or later. Run xcrun simctl list devices available.")
PY
)"
bash scripts/build-ios.sh
app_path="${DERIVED_DATA_PATH:-DerivedData}/Build/Products/${CONFIGURATION:-Debug}-iphonesimulator/MilkOrbit.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
if [[ "$simulator_state" == Shutdown ]]; then
    xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"
echo "Launched $bundle_id on $simulator_id. Open Simulator or Device Hub to play."
