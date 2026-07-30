import Foundation

enum SignalRegistryError: LocalizedError {
    case noDataPacks
    case duplicatePackID(String)
    case duplicateSignal(String, String)
    case invalidPack(String, String)
    case decodeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .noDataPacks:
            return "No diagnostic data packs were found in the application bundle."
        case let .duplicatePackID(id):
            return "Duplicate diagnostic data pack id: \(id)"
        case let .duplicateSignal(signal, pack):
            return "Duplicate signal \(signal) in data pack \(pack)"
        case let .invalidPack(pack, reason):
            return "Invalid diagnostic data pack \(pack): \(reason)"
        case let .decodeFailed(url, error):
            return "Could not decode diagnostic data pack \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Immutable registry assembled from standard, OEM, and community data packs.
/// Vehicle-specific definitions override generic definitions only when their matcher is more specific.
final class SignalRegistryV1 {
    let packs: [DiagnosticDataPackV1]

    private let packsByID: [String: DiagnosticDataPackV1]

    init(packs: [DiagnosticDataPackV1]) throws {
        guard !packs.isEmpty else { throw SignalRegistryError.noDataPacks }

        var ids = Set<String>()
        for pack in packs {
            guard ids.insert(pack.id).inserted else {
                throw SignalRegistryError.duplicatePackID(pack.id)
            }
            try Self.validate(pack)
        }

        self.packs = packs
        self.packsByID = Dictionary(uniqueKeysWithValues: packs.map { ($0.id, $0) })
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> SignalRegistryV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "VehicleDataPacks") ?? []
        if urls.isEmpty {
            urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".diagnostic-pack.json") }
        }

        var decoded: [DiagnosticDataPackV1] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                decoded.append(try decoder.decode(DiagnosticDataPackV1.self, from: Data(contentsOf: url)))
            } catch {
                throw SignalRegistryError.decodeFailed(url, error)
            }
        }
        return try SignalRegistryV1(packs: decoded)
    }

    func pack(id: String) -> DiagnosticDataPackV1? {
        packsByID[id]
    }

    func matchingPacks(for vehicle: VehicleProfileV1) -> [(pack: DiagnosticDataPackV1, score: Int)] {
        packs.compactMap { pack in
            let score = pack.matcher.score(for: vehicle)
            return score >= 0 ? (pack, score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.pack.id < $1.pack.id }
            return $0.score < $1.score
        }
    }

    /// Returns the merged signal catalog. Later, more-specific packs override earlier generic packs.
    func signalDefinitions(for vehicle: VehicleProfileV1) -> [DiagnosticSignalDefinitionV1] {
        var merged: [SignalIdentifierV1: DiagnosticSignalDefinitionV1] = [:]
        for item in matchingPacks(for: vehicle) {
            for signal in item.pack.signals {
                merged[signal.key] = signal
            }
        }
        return merged.values.sorted { $0.key.description < $1.key.description }
    }

    func definition(for key: SignalIdentifierV1, vehicle: VehicleProfileV1) -> DiagnosticSignalDefinitionV1? {
        signalDefinitions(for: vehicle).first { $0.key == key }
    }

    func scenarios(for vehicle: VehicleProfileV1) -> [DiagnosticScenarioDefinitionV1] {
        var merged: [String: DiagnosticScenarioDefinitionV1] = [:]
        for item in matchingPacks(for: vehicle) {
            for scenario in item.pack.scenarios {
                merged[scenario.id] = scenario
            }
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    func provenance(for vehicle: VehicleProfileV1) -> [DiagnosticSourceProvenance] {
        matchingPacks(for: vehicle).map(\.pack.provenance)
    }

    private static func validate(_ pack: DiagnosticDataPackV1) throws {
        guard !pack.schemaVersion.isEmpty else {
            throw SignalRegistryError.invalidPack(pack.id, "schemaVersion is empty")
        }
        guard !pack.version.isEmpty else {
            throw SignalRegistryError.invalidPack(pack.id, "version is empty")
        }
        guard !pack.provenance.license.isEmpty else {
            throw SignalRegistryError.invalidPack(pack.id, "source license is missing")
        }
        guard (0...1).contains(pack.provenance.confidence) else {
            throw SignalRegistryError.invalidPack(pack.id, "confidence must be between 0 and 1")
        }

        var keys = Set<SignalIdentifierV1>()
        for signal in pack.signals {
            guard keys.insert(signal.key).inserted else {
                throw SignalRegistryError.duplicateSignal(signal.key.description, pack.id)
            }
            guard !signal.name.isEmpty else {
                throw SignalRegistryError.invalidPack(pack.id, "signal \(signal.key.description) has no name")
            }
            guard signal.request.timeoutMilliseconds > 0 else {
                throw SignalRegistryError.invalidPack(pack.id, "signal \(signal.key.description) has an invalid timeout")
            }
            if let preferred = signal.preferredFrequencyHz, preferred <= 0 {
                throw SignalRegistryError.invalidPack(pack.id, "signal \(signal.key.description) has an invalid preferred rate")
            }
            if let maximum = signal.maximumFrequencyHz, maximum <= 0 {
                throw SignalRegistryError.invalidPack(pack.id, "signal \(signal.key.description) has an invalid maximum rate")
            }
        }

        var scenarioIDs = Set<String>()
        for scenario in pack.scenarios {
            guard scenarioIDs.insert(scenario.id).inserted else {
                throw SignalRegistryError.invalidPack(pack.id, "duplicate scenario \(scenario.id)")
            }
            guard !scenario.phases.isEmpty else {
                throw SignalRegistryError.invalidPack(pack.id, "scenario \(scenario.id) has no phases")
            }
        }
    }
}
