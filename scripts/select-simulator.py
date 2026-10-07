#!/usr/bin/env python3
"""Print an available iPhone UUID from the newest installed iOS runtime."""
import json
import re
import subprocess
import sys


def choose_simulator(catalog):
    candidates = []
    for runtime in catalog["runtimes"]:
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
            continue
        version = tuple(int(part) for part in re.findall(r"\d+", runtime["version"]))
        for device in catalog["devices"].get(runtime["identifier"], []):
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                # Prefer a running phone when several use the same current runtime.
                candidates.append((version, device.get("state") == "Booted", device["name"], device, runtime))
    if not candidates:
        raise RuntimeError("No available iPhone simulator found. Install an iOS runtime in Xcode Settings > Components.")
    _, _, _, device, runtime = max(candidates, key=lambda item: item[:3])
    return device, runtime


if __name__ == "__main__":
    catalog = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True))
    try:
        device, runtime = choose_simulator(catalog)
    except RuntimeError as error:
        sys.exit(str(error))
    print(f"Using {device['name']} ({runtime['name']}): {device['udid']}", file=sys.stderr)
    print(device["udid"])
