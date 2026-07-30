import Foundation

/// Vehicle-agnostic domain types used by the professional diagnostic platform.
/// These types intentionally do not depend on OBDLink, SwiftUI, or a specific vehicle.
enum DiagnosticTransportKind: String, Codable, CaseIterable {
    case externalAccessory
    case bluetoothLE
    case wifi
    case usb
    case unknown
}

enum DiagnosticApplicationProtocol: String, Codable, CaseIterable {
    case saeJ1979Legacy
    case saeJ1979UDS
    case uds
    case kwp2000
    case j1939
    case rawCAN
    case doip
    case proprietary
    case unknown
}

enum DiagnosticSafetyClass: String, Codable, CaseIterable {
    case passive
    case readOnly
    case restricted
    case write
    case unknown
}

enum DiagnosticSourceKind: String, Codable, CaseIterable {
    case sae
    case iso
    case asamODX
    case dbc
    case arxml
    case cdd
    case manufacturer
    case community
    case userVerified
    case discoveredRaw
}

enum DiagnosticEndian: String, Codable, CaseIterable {
    case big
    case little
}

enum DiagnosticDecodeKind: String, Codable, CaseIterable {
    case linear
    case bitfield
    case lookup
    case ascii
    case boolean
    case expression
    case raw
}

enum DiagnosticSampleQualityStatus: String, Codable, CaseIterable {
    case good
    case stale
    case timeout
    case unsupported
    case invalid
    case estimated
    case rawOnly
}

struct DiagnosticSourceProvenance: Codable, Hashable {
    let id: String
    let name: String
    let version: String
    let kind: DiagnosticSourceKind
    let license: String
    let sourceURL: String?
    let checksum: String?
    let attribution: String?
    let confidence: Double
}

struct ECUFingerprintV1: Codable, Hashable, Identifiable {
    var id: String { address }

    let address: String
    let name: String?
    let responseHeaders: [String]
    let calibrationIDs: [String]
    let cvns: [String]
    let softwareIDs: [String]
    let hardwareIDs: [String]
    let serialNumbers: [String]
}

struct VehicleProfileV1: Codable, Hashable {
    let vin: String?
    let make: String?
    let model: String?
    let modelYear: Int?
    let engine: String?
    let transmission: String?
    let market: String?
    let fuelTypes: [String]
    let transport: DiagnosticTransportKind
    let diagnosticProtocol: DiagnosticApplicationProtocol
    let physicalProtocolDescription: String?
    let ecuFingerprints: [ECUFingerprintV1]
}

struct VehiclePackMatcherV1: Codable, Hashable {
    let makes: [String]
    let models: [String]
    let minimumYear: Int?
    let maximumYear: Int?
    let vinPrefixes: [String]
    let enginePatterns: [String]
    let calibrationIDPrefixes: [String]
    let requiredECUAddresses: [String]

    func score(for vehicle: VehicleProfileV1) -> Int {
        var score = 0

        if !makes.isEmpty {
            guard let make = vehicle.make?.lowercased(),
                  makes.contains(where: { $0.lowercased() == make }) else { return -1 }
            score += 10
        }

        if !models.isEmpty {
            guard let model = vehicle.model?.lowercased(),
                  models.contains(where: { model.contains($0.lowercased()) || $0.lowercased().contains(model) }) else { return -1 }
            score += 10
        }

        if let year = vehicle.modelYear {
            if let minimumYear, year < minimumYear { return -1 }
            if let maximumYear, year > maximumYear { return -1 }
            if minimumYear != nil || maximumYear != nil { score += 4 }
        } else if minimumYear != nil || maximumYear != nil {
            score -= 1
        }

        if !vinPrefixes.isEmpty {
            guard let vin = vehicle.vin?.uppercased(),
                  vinPrefixes.contains(where: { vin.hasPrefix($0.uppercased()) }) else { return -1 }
            score += 20
        }

        if !enginePatterns.isEmpty {
            guard let engine = vehicle.engine?.lowercased(),
                  enginePatterns.contains(where: { engine.contains($0.lowercased()) }) else { return -1 }
            score += 8
        }

        if !calibrationIDPrefixes.isEmpty {
            let calibrationIDs = vehicle.ecuFingerprints.flatMap(\.calibrationIDs).map { $0.uppercased() }
            guard calibrationIDPrefixes.contains(where: { prefix in
                calibrationIDs.contains(where: { $0.hasPrefix(prefix.uppercased()) })
            }) else { return -1 }
            score += 30
        }

        if !requiredECUAddresses.isEmpty {
            let addresses = Set(vehicle.ecuFingerprints.map { $0.address.uppercased() })
            guard requiredECUAddresses.allSatisfy({ addresses.contains($0.uppercased()) }) else { return -1 }
            score += 12
        }

        return score
    }
}

struct SignalIdentifierV1: Codable, Hashable, CustomStringConvertible {
    let namespace: String
    let service: String
    let identifier: String
    let ecuAddress: String?

    var description: String {
        [namespace, ecuAddress, service, identifier]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")
    }
}

struct DiagnosticRequestDefinitionV1: Codable, Hashable {
    let service: String
    let identifier: String
    let header: String?
    let session: String?
    let subfunction: String?
    let timeoutMilliseconds: Int
    let responsePrefix: String?
}

struct DiagnosticDecodeDefinitionV1: Codable, Hashable {
    let kind: DiagnosticDecodeKind
    let startBit: Int?
    let bitLength: Int?
    let endian: DiagnosticEndian?
    let isSigned: Bool?
    let factor: Double?
    let offset: Double?
    let unit: String?
    let expression: String?
    let lookup: [String: String]?
}

struct DiagnosticExpectedRangeV1: Codable, Hashable {
    let minimum: Double?
    let maximum: Double?
    let unit: String?
    let conditions: [String]
}

struct DiagnosticSignalDefinitionV1: Codable, Hashable, Identifiable {
    var id: String { key.description }

    let key: SignalIdentifierV1
    let name: String
    let descriptionText: String?
    let category: String
    let request: DiagnosticRequestDefinitionV1
    let decode: DiagnosticDecodeDefinitionV1
    let safety: DiagnosticSafetyClass
    let preferredFrequencyHz: Double?
    let maximumFrequencyHz: Double?
    let expectedRange: DiagnosticExpectedRangeV1?
    let preconditions: [String]
    let tags: [String]
    let provenance: DiagnosticSourceProvenance
}

struct ScenarioSignalRequirementV1: Codable, Hashable {
    let signal: SignalIdentifierV1
    let required: Bool
    let targetFrequencyHz: Double?
    let rationale: String?
}

struct ScenarioPhaseDefinitionV1: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let instructions: String
    let minimumDurationSeconds: Double
    let maximumDurationSeconds: Double?
    let entryConditions: [String]
    let exitConditions: [String]
    let signals: [ScenarioSignalRequirementV1]
}

struct DiagnosticScenarioDefinitionV1: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let descriptionText: String
    let tags: [String]
    let phases: [ScenarioPhaseDefinitionV1]
}

struct DiagnosticDataPackV1: Codable, Hashable, Identifiable {
    let schemaVersion: String
    let id: String
    let version: String
    let displayName: String
    let matcher: VehiclePackMatcherV1
    let provenance: DiagnosticSourceProvenance
    let signals: [DiagnosticSignalDefinitionV1]
    let scenarios: [DiagnosticScenarioDefinitionV1]
    let researchTargets: [String]
    let notes: [String]
}

struct AdapterCapabilityV1: Codable, Hashable {
    let name: String
    let firmware: String?
    let hardware: String?
    let manufacturer: String?
    let supportedTransports: [DiagnosticTransportKind]
    let maximumRequestsPerSecond: Double?
}

struct DiagnosticCapabilityReportV1: Codable, Hashable {
    let discoveredAt: Date
    let vehicle: VehicleProfileV1
    let adapter: AdapterCapabilityV1
    let supportedServices: [String]
    let supportedSignals: [SignalIdentifierV1]
    let unsupportedSignals: [SignalIdentifierV1]
    let rawResponseHeaders: [String]
    let selectedDataPackIDs: [String]
    let warnings: [String]
}

struct DiagnosticMeasurementQualityV1: Codable, Hashable {
    let status: DiagnosticSampleQualityStatus
    let latencyMilliseconds: Double?
    let ageMilliseconds: Double?
    let sourceFrequencyHz: Double?
    let droppedSamples: Int
    let notes: [String]
}

struct DiagnosticSampleV1: Codable, Hashable {
    let timestamp: Date
    let monotonicMilliseconds: Int64
    let signal: SignalIdentifierV1
    let numericValue: Double?
    let textValue: String?
    let unit: String?
    let rawHex: String?
    let ecuAddress: String?
    let quality: DiagnosticMeasurementQualityV1
}
