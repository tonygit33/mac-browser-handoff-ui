#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "ProfessionalDiagnosticsRuntime.swift"
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:120]!r}")
    text = text.replace(old, new, 1)


replace_once(
    """    private var rawOnlySignals = Set<SignalIdentifierV1>()
""",
    """    private var rawOnlySignals = Set<SignalIdentifierV1>()
    private var userMarkers: [String] = []
""",
)

replace_once(
    """        rawOnlySignals.removeAll()
        structuredFreezeFrames.removeAll()
""",
    """        rawOnlySignals.removeAll()
        userMarkers.removeAll()
        userMarkers.append(Self.timestampedMarker("fuel=\(fuelMode.rawValue)"))
        structuredFreezeFrames.removeAll()
""",
)

replace_once(
    """    func setFuelMode(_ mode: FuelMode) {
        fuelMode = mode
    }
""",
    """    func setFuelMode(_ mode: FuelMode) {
        guard fuelMode != mode else { return }
        fuelMode = mode
        addMarker("fuel=\(mode.rawValue)")
    }

    func addMarker(_ marker: String) {
        let cleaned = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        userMarkers.append(Self.timestampedMarker(cleaned))
        if userMarkers.count > 500 {
            userMarkers.removeFirst(userMarkers.count - 500)
        }
    }
""",
)

replace_once(
    """        guard let directory = sessionDirectory else { return nil }
        closeSamplesFile()
        updateContext(
""",
    """        guard let directory = sessionDirectory else { return nil }
        closeSamplesFile()
        let samplesURL = directory.appendingPathComponent("professional-samples.jsonl")
        let timeSeriesSummary = try? DiagnosticTimeSeriesSummarizer.summarize(samplesURL: samplesURL)
        updateContext(
""",
)

replace_once(
    """                    completedPhaseIDs: [],
                    userMarkers: ["fuel=\(fuelMode.rawValue)", summaryLabel],
""",
    """                    completedPhaseIDs: timeSeriesSummary.map(Self.completedRegimeIDs) ?? [],
                    userMarkers: userMarkers + [Self.timestampedMarker(summaryLabel)],
""",
)

replace_once(
    """            latestSamples: latestSamples.values.sorted { $0.signal.description < $1.signal.description },
            coverage: SignalCoverageSummaryV1(
""",
    """            latestSamples: latestSamples.values.sorted { $0.signal.description < $1.signal.description },
            timeSeriesSummary: timeSeriesSummary,
            coverage: SignalCoverageSummaryV1(
""",
)

replace_once(
    """                warnings: finalCapability.warnings
""",
    """                warnings: finalCapability.warnings + (timeSeriesSummary == nil
                    ? ["Time-series regime summary could not be generated; analysis is limited to latest values."]
                    : [])
""",
)

replace_once(
    """            privacyNotes: ["VIN may identify the vehicle. Location is not collected by OBD Bridge."]
""",
    """            privacyNotes: [
                "The local session may contain the full VIN; cloud payloads hash it on the iPhone before upload.",
                "Location is not collected by OBD Bridge.",
                "The embedded time-series summary contains bounded numeric statistics, not the full raw recording."
            ]
""",
)

insert_anchor = """    private func persist(_ sample: DiagnosticSampleV1) {
"""
insert = """    private static func timestampedMarker(_ marker: String) -> String {
        "\(ISO8601DateFormatter().string(from: Date())) | \(marker)"
    }

    private static func completedRegimeIDs(_ summary: TimeSeriesAnalysisSummaryV1) -> [String] {
        Array(Set(summary.signals.flatMap { $0.byRegime.map { $0.regime.rawValue } })).sorted()
    }

    private func persist(_ sample: DiagnosticSampleV1) {
"""
replace_once(insert_anchor, insert)

path.write_text(text)
print(f"patched {path}")
