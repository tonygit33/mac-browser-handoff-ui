import Foundation

struct SnapshotDatasetV1: Codable, Hashable, Identifiable {
    var id: String { relativePath }

    let relativePath: String
    let mediaType: String
    let formatVersion: String
    let rowCount: Int?
    let startedAt: Date?
    let endedAt: Date?
    let checksumSHA256: String?
    let compression: String?
    let descriptionText: String
}

struct DiagnosticCodeRecordV1: Codable, Hashable {
    let code: String
    let status: String
    let ecuAddress: String?
    let descriptionText: String?
    let descriptionSource: DiagnosticSourceProvenance?
    let rawHex: String
}

struct FreezeFrameRecordV1: Codable, Hashable {
    let frameNumber: Int
    let dtc: String?
    let samples: [DiagnosticSampleV1]
    let rawResponses: [String]
}

struct Mode06RecordV1: Codable, Hashable {
    let monitorID: String
    let testID: String?
    let ecuAddress: String?
    let value: Double?
    let minimum: Double?
    let maximum: Double?
    let unit: String?
    let passed: Bool?
    let rawHex: String
    let provenance: DiagnosticSourceProvenance?
}

struct ScenarioExecutionV1: Codable, Hashable, Identifiable {
    let id: String
    let scenarioDefinitionID: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let completedPhaseIDs: [String]
    let userMarkers: [String]
    let entryConditionsMet: [String]
    let entryConditionsMissing: [String]
    let notes: [String]
}

struct SignalCoverageSummaryV1: Codable, Hashable {
    let discoveredCount: Int
    let decodedCount: Int
    let rawOnlyCount: Int
    let unsupportedCount: Int
    let timedOutCount: Int
    let missingRequiredSignals: [SignalIdentifierV1]
    let missingOptionalSignals: [SignalIdentifierV1]
    let blockedUnsafeSignals: [SignalIdentifierV1]
}

struct DataQualitySummaryV1: Codable, Hashable {
    let durationSeconds: Double
    let totalSamples: Int
    let goodSamples: Int
    let invalidSamples: Int
    let timedOutRequests: Int
    let droppedSamples: Int
    let clockDiscontinuities: Int
    let averageLatencyMilliseconds: Double?
    let observedFrequencyBySignal: [String: Double]
    let warnings: [String]

    var goodSampleRatio: Double {
        guard totalSamples > 0 else { return 0 }
        return Double(goodSamples) / Double(totalSamples)
    }
}

struct SnapshotAnalysisQuestionV1: Codable, Hashable {
    let symptom: String
    let userDescription: String?
    let knownDTCs: [String]
    let requestedSystems: [String]
    let constraints: [String]
}

struct AISnapshotManifestV1: Codable, Hashable, Identifiable {
    let schemaVersion: String
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let captureMode: String
    let readOnly: Bool
    let vehicle: VehicleProfileV1
    let capability: DiagnosticCapabilityReportV1
    let scanPlan: DiagnosticReadPlanV1?
    let scenarios: [ScenarioExecutionV1]
    let datasets: [SnapshotDatasetV1]
    let diagnosticCodes: [DiagnosticCodeRecordV1]
    let freezeFrames: [FreezeFrameRecordV1]
    let mode06Results: [Mode06RecordV1]
    let latestSamples: [DiagnosticSampleV1]
    let coverage: SignalCoverageSummaryV1
    let quality: DataQualitySummaryV1
    let provenance: [DiagnosticSourceProvenance]
    let analysisQuestion: SnapshotAnalysisQuestionV1
    let privacyNotes: [String]
}

struct AIHypothesisEvidenceV1: Codable, Hashable {
    let signal: String?
    let timeRange: String?
    let observation: String
    let supportsHypothesis: Bool
    let strength: Double
}

struct AIDiagnosticHypothesisV1: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let system: String
    let probability: Double
    let confidence: Double
    let explanation: String
    let evidence: [AIHypothesisEvidenceV1]
    let contraryEvidence: [AIHypothesisEvidenceV1]
    let nextReadOnlyTests: [String]
    let repairAdvice: [String]
    let safetyWarnings: [String]
}

struct AIAnalysisResponseV1: Codable, Hashable {
    let schemaVersion: String
    let snapshotID: UUID
    let analyzedAt: Date
    let summary: String
    let hypotheses: [AIDiagnosticHypothesisV1]
    let dataLimitations: [String]
    let missingSignalsThatWouldHelp: [SignalIdentifierV1]
    let recommendedNextScenarioIDs: [String]
    let urgentSafetyAdvice: [String]
    let modelIdentifier: String
}

enum AISnapshotBuilderError: LocalizedError {
    case notReadOnly
    case noDatasets
    case invalidDatasetPath(String)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notReadOnly:
            return "AI diagnostic snapshots must be captured in read-only mode."
        case .noDatasets:
            return "The snapshot does not contain any datasets."
        case let .invalidDatasetPath(path):
            return "Dataset path must be relative and remain inside the session directory: \(path)"
        case let .writeFailed(error):
            return "Could not write AI snapshot: \(error.localizedDescription)"
        }
    }
}

/// Serializes a deterministic manifest next to immutable raw and decoded session files.
struct AISnapshotBuilderV1 {
    let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func validate(_ snapshot: AISnapshotManifestV1) throws {
        guard snapshot.readOnly else { throw AISnapshotBuilderError.notReadOnly }
        guard !snapshot.datasets.isEmpty else { throw AISnapshotBuilderError.noDatasets }

        for dataset in snapshot.datasets {
            let path = dataset.relativePath
            if path.hasPrefix("/") || path.contains("..") || path.isEmpty {
                throw AISnapshotBuilderError.invalidDatasetPath(path)
            }
        }
    }

    @discardableResult
    func write(_ snapshot: AISnapshotManifestV1, to sessionDirectory: URL) throws -> URL {
        try validate(snapshot)
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let destination = sessionDirectory.appendingPathComponent("ai-snapshot.json")
            let temporary = sessionDirectory.appendingPathComponent(".ai-snapshot.json.tmp")
            try encoder.encode(snapshot).write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            throw AISnapshotBuilderError.writeFailed(error)
        }
    }
}
