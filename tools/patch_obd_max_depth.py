from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing patch target: {label}")
    return text.replace(old, new, 1)


accessory = Path("obd-bridge/OBDBridge/AccessoryBridge.swift")
text = accessory.read_text()
text = text.replace("through: 0xC0", "through: 0xE0")
text = replace_once(
    text,
    """            let supportedDefinitions = supportedPIDs
                .filter { PIDCatalog.definitions[$0] != nil }
                .sorted()
            let selectedPIDs = supportedDefinitions.isEmpty
                ? ScanPreset.p2188Idle.preferredPIDs
                : supportedDefinitions
""",
    """            // Query every PID advertised by any responding ECU. Unknown formulas remain raw.
            let discovered = supportedPIDs
                .filter { $0 % 0x20 != 0 }
                .sorted()
            let selectedPIDs = discovered.isEmpty
                ? ScanPreset.p2188Idle.preferredPIDs
                : discovered
""",
    "all-discovered PID selection",
)
text = replace_once(
    text,
    """        let filtered = preset.preferredPIDs.filter {
            PIDCatalog.definitions[$0] != nil && (supportedPIDs.isEmpty || supportedPIDs.contains($0))
        }
""",
    """        let requested: [UInt8]
        if preset == .allSupported, !supportedPIDs.isEmpty {
            requested = supportedPIDs.filter { $0 % 0x20 != 0 }.sorted()
        } else {
            requested = preset.preferredPIDs
        }
        let filtered = requested.filter { supportedPIDs.isEmpty || supportedPIDs.contains($0) }
""",
    "continuous all-supported selection",
)
accessory.write_text(text)

models = Path("obd-bridge/OBDBridge/OBDModels.swift")
text = models.read_text()
text = replace_once(
    text,
    """        guard let data = payloads(service: 0x41, pid: pid, response: response).first,
              let definition = PIDCatalog.definitions[pid] else { return nil }
""",
    """        guard let data = payloads(service: 0x41, pid: pid, response: response).first else { return nil }
        let definition = PIDCatalog.definitions[pid]
            ?? PIDDefinition(pid: pid, name: String(format: "SAE PID 0x%02X", pid), unit: "raw")
""",
    "raw fallback decoder",
)
start = text.index("    static func supportedIDs(")
end = text.index("    static func decodeMode01", start)
text = text[:start] + """    static func supportedIDs(responseService: UInt8, base: UInt8, response: String) -> Set<UInt8> {
        var result = Set<UInt8>()
        for data in payloads(service: responseService, pid: base, response: response) where data.count >= 4 {
            for (byteIndex, byte) in data.prefix(4).enumerated() {
                for bit in 0..<8 where (byte & (1 << (7 - bit))) != 0 {
                    let value = Int(base) + byteIndex * 8 + bit + 1
                    if value <= 0xFF { result.insert(UInt8(value)) }
                }
            }
        }
        return result
    }

""" + text[end:]
models.write_text(text)

project = Path("obd-bridge/project.yml")
text = project.read_text()
text = text.replace('CFBundleShortVersionString: "0.2.0"', 'CFBundleShortVersionString: "0.2.1"')
text = text.replace('CFBundleVersion: "2"', 'CFBundleVersion: "3"')
text = text.replace('MARKETING_VERSION: "0.2.0"', 'MARKETING_VERSION: "0.2.1"')
text = text.replace('CURRENT_PROJECT_VERSION: "2"', 'CURRENT_PROJECT_VERSION: "3"')
text = replace_once(
    text,
    "        NSBluetoothAlwaysUsageDescription:",
    "        UIFileSharingEnabled: true\n        LSSupportsOpeningDocumentsInPlace: true\n        NSBluetoothAlwaysUsageDescription:",
    "Files app metadata",
)
project.write_text(text)

plist = Path("obd-bridge/OBDBridge/Info.plist")
text = plist.read_text()
text = text.replace("<string>0.2.0</string>", "<string>0.2.1</string>")
text = text.replace("<string>2</string>", "<string>3</string>", 1)
text = replace_once(
    text,
    "    <key>NSBluetoothAlwaysUsageDescription</key>",
    "    <key>UIFileSharingEnabled</key>\n    <true/>\n    <key>LSSupportsOpeningDocumentsInPlace</key>\n    <true/>\n    <key>NSBluetoothAlwaysUsageDescription</key>",
    "source plist file sharing",
)
plist.write_text(text)

# Remove this one-shot patch from the resulting tree.
Path(__file__).unlink()
