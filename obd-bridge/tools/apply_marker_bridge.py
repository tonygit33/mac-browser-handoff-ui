#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "AccessoryBridge.swift"
text = path.read_text()

old = """    func addMarker(_ text: String) {
        guard recorder.currentDirectory != nil else {
            appendLog("Start a scan or logging session before adding markers.")
            return
        }
        recorder.marker(text)
        appendLog("MARKER: \(text)")
    }
"""
new = """    func addMarker(_ text: String) {
        guard recorder.currentDirectory != nil else {
            appendLog("Start a scan or logging session before adding markers.")
            return
        }
        recorder.marker(text)
        professional.addMarker(text)
        appendLog("MARKER: \(text)")
    }
"""
if text.count(old) != 1:
    raise SystemExit(f"expected marker method once, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}")
