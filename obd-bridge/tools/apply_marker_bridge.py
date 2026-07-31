#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "AccessoryBridge.swift"
text = path.read_text()

old = """    func addMarker(_ marker: String) {
        guard isLogging else { return }
        recorder.marker(marker)
    }
"""
new = """    func addMarker(_ marker: String) {
        guard isLogging else { return }
        recorder.marker(marker)
        professional.addMarker(marker)
    }
"""
if text.count(old) != 1:
    raise SystemExit(f"expected marker method once, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}")
