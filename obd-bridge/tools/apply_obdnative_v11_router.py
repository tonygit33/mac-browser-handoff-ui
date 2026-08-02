#!/usr/bin/env python3
"""Wire OBDNativeV11Router into the current NativeWebBridge.swift.

This script edits source only. It does not build, sign or deploy the iOS application.
It is intentionally idempotent and fails when expected safety anchors are missing.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "OBDBridge" / "NativeWebBridge.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count == 0 and new in text:
        return text
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    text = BRIDGE.read_text(encoding="utf-8")

    text = replace_once(
        text,
        'static let bridgeVersion = "1.0"',
        'static let bridgeVersion = OBDLinkCapabilityCatalog.apiVersion',
        "bridge version",
    )
    text = replace_once(
        text,
        "version: '1.0'",
        "version: '1.1'",
        "JavaScript bridge version",
    )

    old_switch_tail = '''            case "app.reload": resolve(id: id, value: ["accepted": true]); DispatchQueue.main.async { [weak self] in self?.loadInitialPage() }
            default: reject(id: id, message: "Unknown native method: \\(method)")
'''
    new_switch_tail = '''            case "app.reload": resolve(id: id, value: ["accepted": true]); DispatchQueue.main.async { [weak self] in self?.loadInitialPage() }
            case let structuredMethod where OBDNativeV11Router.handles(structuredMethod):
                do {
                    let value = try OBDNativeV11Router.handle(method: structuredMethod, params: params, bridge: bridge)
                    resolve(id: id, value: value)
                } catch {
                    reject(id: id, message: error.localizedDescription)
                }
            default: reject(id: id, message: "Unknown native method: \\(method)")
'''
    text = replace_once(text, old_switch_tail, new_switch_tail, "router switch")

    text = replace_once(
        text,
        '"events": ["state", "log", "log-reset", "native-ready"],',
        '"structuredMethods": OBDNativeV11Router.methods, "events": ["state", "log", "log-reset", "native-ready"],',
        "bridge info methods",
    )
    text = replace_once(
        text,
        '["command": ReadOnlyCommandPolicy.normalize(command), "allowed": ReadOnlyCommandPolicy.isAllowed(command), "policy": "native-read-only-v2"]',
        '["command": ReadOnlyCommandPolicy.normalize(command), "allowed": ReadOnlyCommandPolicy.isAllowed(command), "policy": OBDLinkCapabilityCatalog.policyVersion]',
        "policy version",
    )

    BRIDGE.write_text(text, encoding="utf-8")
    print(f"wired OBDNative API {OBDLinkCapabilityCatalog.apiVersion if False else '1.1'} into {BRIDGE}")


if __name__ == "__main__":
    main()
