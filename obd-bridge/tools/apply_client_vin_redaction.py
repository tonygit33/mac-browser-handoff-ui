#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "ProfessionalDiagnosticsCompletion.swift"
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:100]!r}")
    text = text.replace(old, new, 1)


if text.startswith("import Foundation\n"):
    text = text.replace("import Foundation\n", "import CryptoKit\nimport Foundation\n", 1)

replace_once(
    """                    )
                }

                var request = URLRequest(url: endpoint)""",
    """                    )
                }
                let cloudPayload = try Self.cloudPayload(from: snapshotData)

                var request = URLRequest(url: endpoint)""",
)
replace_once("request.httpBody = snapshotData", "request.httpBody = cloudPayload")
replace_once(
    'detail: "The cloud service analyzed the read-only snapshot."',
    'detail: "The cloud service analyzed the read-only snapshot. The VIN was hashed on this iPhone before upload."',
)
replace_once(
    """    func configureForUITesting() {
""",
    """    static func cloudPayload(from snapshotData: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] else {
            throw NSError(
                domain: "OBDAnalysis",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Snapshot is not a JSON object."]
            )
        }
        guard var vehicle = root["vehicle"] as? [String: Any],
              let vin = vehicle["vin"] as? String,
              !vin.isEmpty else {
            return snapshotData
        }

        let digest = SHA256.hash(data: Data(vin.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        vehicle.removeValue(forKey: "vin")
        vehicle["vinHash"] = String(digest.prefix(16))
        root["vehicle"] = vehicle
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func configureForUITesting() {
""",
)

path.write_text(text)
print(f"patched {path}")
