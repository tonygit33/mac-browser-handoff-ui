import XCTest
@testable import OBDBridge

final class LocalAnalysisTests: XCTestCase {
    func testP2188SnapshotProducesRankedEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshotURL = directory.appendingPathComponent("ai-snapshot.json")
        let snapshot: [String: Any] = [
            "schemaVersion": "1.0",
            "id": "qa-p2188",
            "readOnly": true,
            "analysisQuestion": ["knownDTCs": ["P2188"]],
            "diagnosticCodes": [["code": "P2188", "status": "stored"]],
            "latestSamples": [
                sample(signalID: "SHRTFT1", identifier: "06", value: -22.0, unit: "%"),
                sample(signalID: "LONGFT1", identifier: "07", value: -8.0, unit: "%"),
                sample(signalID: "RPM", identifier: "0C", value: 760.0, unit: "rpm"),
                sample(signalID: "EVAP_PURGE", identifier: "2E", value: 12.0, unit: "%")
            ],
            "quality": ["totalSamples": 100, "goodSamples": 96],
            "freezeFrames": [],
            "mode06Results": []
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: snapshotURL)

        let result = try LocalOBDAnalysisEngine.analyze(snapshotURL: snapshotURL)
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))

        let resultData = try Data(contentsOf: result.url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "1.0")
        XCTAssertEqual(object["snapshotID"] as? String, "qa-p2188")
        XCTAssertEqual(object["engine"] as? String, "rules-on-device")

        let hypotheses = try XCTUnwrap(object["hypotheses"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(hypotheses.count, 3)
        XCTAssertEqual(hypotheses.first?["id"] as? String, "evap-purge-leak")
        XCTAssertFalse((hypotheses.first?["evidence"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testRejectsNonReadOnlySnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("ai-snapshot.json")
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": "1.0", "readOnly": false])
        try data.write(to: url)
        XCTAssertThrowsError(try LocalOBDAnalysisEngine.analyze(snapshotURL: url))
    }

    func testCloudPayloadHashesVINBeforeUpload() throws {
        let original: [String: Any] = [
            "schemaVersion": "1.0",
            "readOnly": true,
            "vehicle": [
                "vin": "JMZCR19F270123456",
                "make": "Mazda",
                "model": "5"
            ]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let cloudData = try OBDAnalysisClient.cloudPayload(from: originalData)
        let cloudObject = try XCTUnwrap(JSONSerialization.jsonObject(with: cloudData) as? [String: Any])
        let vehicle = try XCTUnwrap(cloudObject["vehicle"] as? [String: Any])

        XCTAssertNil(vehicle["vin"])
        XCTAssertEqual((vehicle["vinHash"] as? String)?.count, 16)
        XCTAssertEqual(vehicle["make"] as? String, "Mazda")
        XCTAssertFalse(String(data: cloudData, encoding: .utf8)?.contains("JMZCR19F270123456") == true)

        let untouchedOriginal = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        let originalVehicle = try XCTUnwrap(untouchedOriginal["vehicle"] as? [String: Any])
        XCTAssertEqual(originalVehicle["vin"] as? String, "JMZCR19F270123456")
    }

    private func sample(signalID: String, identifier: String, value: Double, unit: String) -> [String: Any] {
        [
            "timestamp": "2026-07-31T06:00:00Z",
            "signal": [
                "namespace": "sae",
                "service": "01",
                "identifier": identifier,
                "signalID": signalID
            ],
            "numericValue": value,
            "unit": unit,
            "quality": ["status": "good"]
        ]
    }
}
