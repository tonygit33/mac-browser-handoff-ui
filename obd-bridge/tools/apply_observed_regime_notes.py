#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "ProfessionalDiagnosticsRuntime.swift"
text = path.read_text()

old = """                    completedPhaseIDs: timeSeriesSummary.map(Self.completedRegimeIDs) ?? [],
                    userMarkers: userMarkers + [Self.timestampedMarker(summaryLabel)],
                    entryConditionsMet: [],
                    entryConditionsMissing: [],
                    notes: []
"""
new = """                    completedPhaseIDs: [],
                    userMarkers: userMarkers + [Self.timestampedMarker(summaryLabel)],
                    entryConditionsMet: [],
                    entryConditionsMissing: [],
                    notes: timeSeriesSummary.map {
                        ["Observed operating regimes: \(Self.observedRegimeIDs($0).joined(separator: ", "))"]
                    } ?? ["Operating regimes could not be summarized."]
"""
if text.count(old) != 1:
    raise SystemExit(f"expected scenario block once, found {text.count(old)}")
text = text.replace(old, new, 1)
text = text.replace(
    "private static func completedRegimeIDs(_ summary: TimeSeriesAnalysisSummaryV1) -> [String]",
    "private static func observedRegimeIDs(_ summary: TimeSeriesAnalysisSummaryV1) -> [String]",
    1,
)
path.write_text(text)
print(f"patched {path}")
