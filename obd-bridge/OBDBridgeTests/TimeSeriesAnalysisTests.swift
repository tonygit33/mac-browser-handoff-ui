import XCTest
@testable import OBDBridge

final class TimeSeriesAnalysisTests: XCTestCase {
    func testStreamingSummarySeparatesIdleAndElevatedRPM() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let summary = try DiagnosticTimeSeriesSummarizer.summarize(samplesURL: fixture.samplesURL)
        XCTAssertEqual(summary.totalRows, 6)
        XCTAssertEqual(summary.numericRows, 6)

        let stft = try XCTUnwrap(summary.signals.first(where: { $0.signal.identifier == "06" }))
        let idle = try XCTUnwrap(stft.byRegime.first(where: { $0.regime == .idle }))
        let elevated = try XCTUnwrap(stft.byRegime.first(where: { $0.regime == .elevatedRPM }))
        XCTAssertEqual(idle.statistics.mean, -20, accuracy: 0.001)
        XCTAssertEqual(elevated.statistics.mean, -5, accuracy: 0.001)
        XCTAssertEqual(idle.statistics.count, 1)
        XCTAssertEqual(elevated.statistics.count, 1)
    }

    func testP2188DifferentialUsesSeriesNotFinalValueOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let summary = try DiagnosticTimeSeriesSummarizer.summarize(samplesURL: fixture.samplesURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let summaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(summary)) as? [String: Any]
        )
        let snapshot: [String: Any] = [
            "schemaVersion": "1.0",
            "id": "qa-series-p2188",
            "readOnly": true,
            "analysisQuestion": ["knownDTCs": ["P2188"]],
            "diagnosticCodes": [["code": "P2188", "status": "stored"]],
            // Final values are from elevated RPM and are only mildly negative.
            "latestSamples": [
                jsonSample(signalID: "RPM", identifier: "0C", value: 2_500, unit: "rpm"),
                jsonSample(signalID: "SHRTFT1", identifier: "06", value: -5, unit: "%"),
                jsonSample(signalID: "LONGFT1", identifier: "07", value: -4, unit: "%")
            ],
            "timeSeriesSummary": summaryObject,
            "quality": ["totalSamples": 6, "goodSamples": 6],
            "freezeFrames": [],
            "mode06Results": []
        ]
        let snapshotURL = fixture.directory.appendingPathComponent("ai-snapshot.json")
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            .write(to: snapshotURL)

        let result = try LocalOBDAnalysisEngine.analyze(snapshotURL: snapshotURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any]
        )
        let hypotheses = try XCTUnwrap(object["hypotheses"] as? [[String: Any]])
        XCTAssertEqual(hypotheses.first?["id"] as? String, "evap-purge-leak")
        let probability = try XCTUnwrap((hypotheses.first?["probability"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(probability, 0.76, accuracy: 0.001)
        let evidence = hypotheses.first?["evidence"] as? [[String: Any]] ?? []
        XCTAssertTrue(evidence.contains(where: { ($0["timeRange"] as? String) == "idle→elevatedRPM" }))
    }

    private func makeFixture() throws -> (directory: URL, samplesURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samplesURL = directory.appendingPathComponent("professional-samples.jsonl")

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            sample(signalID: "RPM", identifier: "0C", value: 750, unit: "rpm", at: base),
            sample(signalID: "SHRTFT1", identifier: "06", value: -20, unit: "%", at: base.addingTimeInterval(1)),
            sample(signalID: "LONGFT1", identifier: "07", value: -8, unit: "%", at: base.addingTimeInterval(2)),
            sample(signalID: "RPM", identifier: "0C", value: 2_500, unit: "rpm", at: base.addingTimeInterval(3)),
            sample(signalID: "SHRTFT1", identifier: "06", value: -5, unit: "%", at: base.addingTimeInterval(4)),
            sample(signalID: "LONGFT1", identifier: "07", value: -4, unit: "%", at: base.addingTimeInterval(5))
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        try data.write(to: samplesURL)
        return (directory, samplesURL)
    }

    private func sample(
        signalID: String,
        identifier: String,
        value: Double,
        unit: String,
        at date: Date
    ) -> DiagnosticSampleV1 {
        DiagnosticSampleV1(
            timestamp: date,
            monotonicMilliseconds: Int64(date.timeIntervalSince1970 * 1_000),
            signal: SignalIdentifierV1(
                namespace: "sae",
                service: "01",
                identifier: identifier,
                signalID: signalID,
                ecuAddress: nil
            ),
            numericValue: value,
            textValue: String(value),
            unit: unit,
            rawHex: nil,
            ecuAddress: nil,
            quality: DiagnosticMeasurementQualityV1(
                status: .good,
                latencyMilliseconds: nil,
                ageMilliseconds: 0,
                sourceFrequencyHz: 1,
                droppedSamples: 0,
                notes: []
            )
        )
    }

    private func jsonSample(signalID: String, identifier: String, value: Double, unit: String) -> [String: Any] {
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
