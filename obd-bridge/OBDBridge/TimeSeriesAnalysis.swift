import Foundation

enum DiagnosticOperatingRegimeV1: String, Codable, Hashable, CaseIterable {
    case idle
    case elevatedRPM
    case moving
    case unknown
}

struct NumericStatisticsV1: Codable, Hashable {
    let count: Int
    let minimum: Double
    let maximum: Double
    let mean: Double
    let last: Double
}

struct SignalRegimeStatisticsV1: Codable, Hashable {
    let regime: DiagnosticOperatingRegimeV1
    let statistics: NumericStatisticsV1
}

struct SignalTimeSeriesSummaryV1: Codable, Hashable {
    let signal: SignalIdentifierV1
    let unit: String?
    let overall: NumericStatisticsV1
    let byRegime: [SignalRegimeStatisticsV1]
}

struct TimeSeriesAnalysisSummaryV1: Codable, Hashable {
    let schemaVersion: String
    let totalRows: Int
    let numericRows: Int
    let startedAt: Date?
    let endedAt: Date?
    let signals: [SignalTimeSeriesSummaryV1]
}

enum DiagnosticTimeSeriesSummarizerError: LocalizedError {
    case fileMissing
    case noNumericSamples

    var errorDescription: String? {
        switch self {
        case .fileMissing: return "Professional sample dataset is missing."
        case .noNumericSamples: return "Professional sample dataset contains no numeric values."
        }
    }
}

/// Converts an arbitrarily long JSONL recording into a bounded set of signal statistics.
/// The summary carries enough evidence for idle-vs-2500-vs-moving comparisons without
/// uploading the full raw recording or retaining every sample in memory.
enum DiagnosticTimeSeriesSummarizer {
    private struct Accumulator {
        var count = 0
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var last = 0.0

        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            count += 1
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            last = value
        }

        var statistics: NumericStatisticsV1? {
            guard count > 0 else { return nil }
            return NumericStatisticsV1(
                count: count,
                minimum: minimum,
                maximum: maximum,
                mean: sum / Double(count),
                last: last
            )
        }
    }

    private struct SignalAccumulator {
        var unit: String?
        var overall = Accumulator()
        var regimes: [DiagnosticOperatingRegimeV1: Accumulator] = [:]
    }

    static func summarize(samplesURL: URL) throws -> TimeSeriesAnalysisSummaryV1 {
        guard FileManager.default.fileExists(atPath: samplesURL.path) else {
            throw DiagnosticTimeSeriesSummarizerError.fileMissing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var signals: [SignalIdentifierV1: SignalAccumulator] = [:]
        var latestRPM: Double?
        var latestSpeed: Double?
        var totalRows = 0
        var numericRows = 0
        var startedAt: Date?
        var endedAt: Date?

        try enumerateJSONLines(at: samplesURL) { line in
            guard !line.isEmpty else { return }
            guard let sample = try? decoder.decode(DiagnosticSampleV1.self, from: line) else { return }
            totalRows += 1
            startedAt = minDate(startedAt, sample.timestamp)
            endedAt = maxDate(endedAt, sample.timestamp)

            guard let value = sample.numericValue, value.isFinite else { return }
            numericRows += 1
            if isRPM(sample.signal) { latestRPM = value }
            if isVehicleSpeed(sample.signal) { latestSpeed = value }
            let regime = classify(rpm: latestRPM, speed: latestSpeed)

            var accumulator = signals[sample.signal] ?? SignalAccumulator()
            if accumulator.unit == nil { accumulator.unit = sample.unit }
            accumulator.overall.add(value)
            var regimeAccumulator = accumulator.regimes[regime] ?? Accumulator()
            regimeAccumulator.add(value)
            accumulator.regimes[regime] = regimeAccumulator
            signals[sample.signal] = accumulator
        }

        guard numericRows > 0 else { throw DiagnosticTimeSeriesSummarizerError.noNumericSamples }
        let summaries = signals.compactMap { signal, accumulator -> SignalTimeSeriesSummaryV1? in
            guard let overall = accumulator.overall.statistics else { return nil }
            let regimes = accumulator.regimes.compactMap { regime, values -> SignalRegimeStatisticsV1? in
                guard let statistics = values.statistics else { return nil }
                return SignalRegimeStatisticsV1(regime: regime, statistics: statistics)
            }
            .sorted { $0.regime.rawValue < $1.regime.rawValue }
            return SignalTimeSeriesSummaryV1(
                signal: signal,
                unit: accumulator.unit,
                overall: overall,
                byRegime: regimes
            )
        }
        .sorted { $0.signal.description < $1.signal.description }

        return TimeSeriesAnalysisSummaryV1(
            schemaVersion: "1.0",
            totalRows: totalRows,
            numericRows: numericRows,
            startedAt: startedAt,
            endedAt: endedAt,
            signals: summaries
        )
    }

    private static func classify(rpm: Double?, speed: Double?) -> DiagnosticOperatingRegimeV1 {
        if let speed, speed > 3 { return .moving }
        if let rpm {
            if rpm >= 450, rpm <= 1_200 { return .idle }
            if rpm >= 1_800, rpm <= 3_200 { return .elevatedRPM }
        }
        return .unknown
    }

    private static func isRPM(_ signal: SignalIdentifierV1) -> Bool {
        signal.identifier.uppercased() == "0C"
            || signal.signalID?.lowercased().contains("rpm") == true
            || signal.signalID?.lowercased().contains("engine_speed") == true
    }

    private static func isVehicleSpeed(_ signal: SignalIdentifierV1) -> Bool {
        signal.identifier.uppercased() == "0D"
            || signal.signalID?.lowercased().contains("vehicle_speed") == true
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static func enumerateJSONLines(at url: URL, body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                try body(line)
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty { try body(buffer) }
    }
}
