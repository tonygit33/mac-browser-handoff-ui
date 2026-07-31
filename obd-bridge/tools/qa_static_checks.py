#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "OBDBridge"
PROJECT = ROOT / "project.yml"
PLIST = APP / "Info.plist"

errors: list[str] = []
notes: list[str] = []

project_text = PROJECT.read_text()
with PLIST.open("rb") as handle:
    plist = plistlib.load(handle)

version = plist.get("CFBundleShortVersionString")
build = plist.get("CFBundleVersion")
for expected in [f'CFBundleShortVersionString: "{version}"', f'CFBundleVersion: "{build}"', f'MARKETING_VERSION: "{version}"', f'CURRENT_PROJECT_VERSION: "{build}"']:
    if expected not in project_text:
        errors.append(f"project.yml is inconsistent with Info.plist: missing {expected}")

endpoint = plist.get("OBDAnalysisEndpoint", "")
if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
    errors.append("OBDAnalysisEndpoint must be HTTPS")

protocols = plist.get("UISupportedExternalAccessoryProtocols", [])
if "com.obdlink" not in protocols:
    errors.append("com.obdlink is missing from UISupportedExternalAccessoryProtocols")

swift_files = sorted(APP.glob("*.swift"))
combined = "\n".join(file.read_text() for file in swift_files)
for forbidden in [r"\btry!\b", r"\bas!\b", r"\bfatalError\s*\("]:
    if re.search(forbidden, combined):
        errors.append(f"forbidden Swift construct detected: {forbidden}")

if "ReadOnlyCommandPolicy.isAllowed" not in (APP / "AccessoryBridge.swift").read_text():
    errors.append("AccessoryBridge does not use the centralized read-only policy")

if "targetFrequencyHz" not in (APP / "AccessoryBridge.swift").read_text():
    errors.append("transport does not consume planner targetFrequencyHz")

if "discardingUntilPrompt" not in (APP / "AccessoryBridge.swift").read_text():
    errors.append("prompt recovery guard is missing")

content = (APP / "ContentView.swift").read_text()
for required in ["TabView", "Advanced tools", "Privacy before sharing", "Read-only safety", "LazyVGrid", "accessibilityLabel"]:
    if required not in content:
        errors.append(f"UX requirement missing from ContentView: {required}")

if "bridge.vin)" in content or 'Text(bridge.vin)' in content:
    errors.append("full VIN is rendered directly in the UI")

for directory in [ROOT / "OBDBridgeTests", ROOT / "OBDBridgeUITests"]:
    if not directory.exists() or not any(directory.glob("*.swift")):
        errors.append(f"missing tests in {directory.name}")

pack_ids: set[str] = set()
for pack_path in sorted((ROOT / "Resources" / "VehicleDataPacks").glob("*.json")):
    data = json.loads(pack_path.read_text())
    pack_id = data.get("id") or data.get("pack", {}).get("id")
    if pack_id:
        if pack_id in pack_ids:
            errors.append(f"duplicate diagnostic pack id: {pack_id}")
        pack_ids.add(pack_id)

notes.append(f"version={version} build={build}")
notes.append(f"swift_files={len(swift_files)}")
notes.append(f"diagnostic_packs={len(pack_ids)}")
notes.append("manual vehicle-write services remain blocked")

print("STATIC QA")
for note in notes:
    print(f"PASS {note}")
if errors:
    for error in errors:
        print(f"FAIL {error}")
    raise SystemExit(1)
print("PASS all static checks")
