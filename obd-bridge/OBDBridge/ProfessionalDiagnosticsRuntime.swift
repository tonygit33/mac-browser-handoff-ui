import CryptoKit
import Foundation

/// Live bridge between the prompt-driven OBDLink transport and the professional,
/// vehicle-agnostic diagnostic domain model.
final class ProfessionalDiagnosticsRuntime: ObservableObject {
    @Published private(set) var status = "Loading diagnostic data packs…"
    @Published private(set) var selectedPackIDs: [String] = []
    @Published private(set) var availableScenarioIDs: [String] = []
    @Published private(set) var decodedSignalCount = 0
    @Published private(set) var lastSnapshotURL: URL?

    private(set) var vehicleProfile = VehicleProfileV1(
        vin: nil,
        make: nil,
        model: nil,
        modelYear: nil,
        engine: nil,
        transmission: nil,
        market: nil,
        fuelTypes: [],
        transport: .externalAccessory,
        diagnosticProtocol: .unknown,
        physicalProtocolDescription: nil,
        ecuFingerprints: []
    )

    private var registry: SignalRegistryV1?
    private var capability: DiagnosticCapabilityReportV1?
    private var sessionDirectory: URL?
    private var samplesHandle: FileHandle?
    private var sessionStartedAt: Date?
    private var scenarioLabel = ""
    private var fuelMode: FuelMode = .unknown
    private var latestSamples: [SignalIdentifierV1: DiagnosticSampleV1] = [:]
    private var sampleCounts: [SignalIdentifierV1: Int] = [:]
    private var firstSampleAt: [SignalIdentifierV1: Date] = [:]
    private var lastSampleAt: [SignalIdentifierV1: Date] = [:]
    private var totalSamples = 0
    private var invalidSamples = 0
    private var timedOutRequests = 0
    private var rawOnlySignals = Set<SignalIdentifierV1>()

    init() {
        do {
            registry = try SignalRegistryV1.loadBundled()
            status = "Diagnostic packs loaded"
        } catch {
            status = "Data-pack error: \(error.localizedDescription)"
        }
    }

    var vehicleDisplayName: String {
        let parts: [String?] = [
            vehicleProfile.make,
            vehicleProfile.model,
            vehicleProfile.modelYear.map(String.init)
        ]
        let result = parts.compactMap { $0 }.joined(separator: " ")
        return result.isEmpty ? (vehicleProfile.vin ?? "Auto-detected vehicle") : result
    }

    func beginSession(directory: URL?, fuelMode: FuelMode, scenario: String) {
        closeSamplesFile()
        guard let directory else { return }

        sessionDirectory = directory
        sessionStartedAt = Date()
        scenarioLabel = scenario
        self.fuelMode = fuelMode
        latestSamples.removeAll()
        sampleCounts.removeAll()
        firstSampleAt.removeAll()
        lastSampleAt.removeAll()
        totalSamples = 0
        invalidSamples = 0
        timedOutRequests = 0
        rawOnlySignals.removeAll()
        lastSnapshotURL = nil

        let samplesURL = directory.appendingPathComponent("professional-samples.jsonl")
        FileManager.default.createFile(atPath: samplesURL.path, contents: nil)
        samplesHandle = try? FileHandle(forWritingTo: samplesURL)
        status = registry == nil ? "Recording raw data; diagnostic packs unavailable" : "Professional recording active"
    }

    func setFuelMode(_ mode: FuelMode) {
        fuelMode = mode
    }

    func markTimeout() {
        timedOutRequests += 1
    }

    func updateContext(
        vin: String,
        protocolDescription: String,
        adapterDetails: [String: String],
        supportedPIDs: Set<UInt8>
    ) {
        vehicleProfile = Self.resolveVehicle(
            vin: vin.isEmpty ? nil : vin,
            protocolDescription: protocolDescription,
            adapterDetails: adapterDetails
        )

        guard let registry else { return }
        let definitions = registry.signalDefinitions(for: vehicleProfile)
        let supportedSignals = definitions.compactMap { definition -> SignalIdentifierV1? in
            guard definition.request.service.uppercased() == "01",
                  let pid = UInt8(definition.request.identifier, radix: 16),
                  supportedPIDs.contains(pid) else { return nil }
            return definition.key
        }

        selectedPackIDs = registry.matchingPacks(for: vehicleProfile).map(\.pack.id)
        availableScenarioIDs = registry.scenarios(for: vehicleProfile).map(\.id)
        capability = DiagnosticCapabilityReportV1(
            discoveredAt: Date(),
            vehicle: vehicleProfile,
            adapter: AdapterCapabilityV1(
                name: adapterDetails["extendedDevice"] ?? "OBDLink MX+",
                firmware: adapterDetails["firmware"] ?? adapterDetails["extendedFirmware"],
                hardware: adapterDetails["hardware"],
                manufacturer: adapterDetails["manufacturer"] ?? "OBD Solutions LLC",
                supportedTransports: [.externalAccessory],
                maximumRequestsPerSecond: Self.requestBudget(protocolDescription: protocolDescription)
            ),
            supportedServices: ["01", "02", "03", "06", "07", "09", "0A"],
            supportedSignals: supportedSignals,
            unsupportedSignals: [],
            rawResponseHeaders: [],
            selectedDataPackIDs: selectedPackIDs,
            warnings: supportedPIDs.isEmpty ? ["Supported PID discovery is incomplete."] : []
        )
        status = selectedPackIDs.isEmpty
            ? "No matching data packs; preserving raw responses"
            : "Active packs: \(selectedPackIDs.joined(separator: ", "))"
    }

    /// Decode every concrete signal defined for one Mode 01 PID. A single request may
    /// produce several samples; it is still sent only once by the scan planner.
    @discardableResult
    func recordMode01(pid: UInt8, response: String) -> [DiagnosticSampleV1] {
        guard let registry else { return [] }
        let requestKey = SignalIdentifierV1(
            namespace: "sae",
            service: "01",
            identifier: String(format: "%02X", pid),
            signalID: nil,
            ecuAddress: nil
        )
        let definitions = registry.resolvedDefinitions(for: requestKey, vehicle: vehicleProfile)
        let payloads = OBDDecoder.payloads(service: 0x41, pid: pid, response: response)
        guard let payload = payloads.first else {
            invalidSamples += 1
            return []
        }

        if definitions.isEmpty {
            let key = SignalIdentifierV1(
                namespace: "sae",
                service: "01",
                identifier: String(format: "%02X", pid),
                signalID: "raw",
                ecuAddress: nil
            )
            rawOnlySignals.insert(key)
            let sample = DiagnosticSampleV1(
                timestamp: Date(),
                monotonicMilliseconds: elapsedMilliseconds(),
                signal: key,
                numericValue: nil,
                textValue: nil,
                unit: nil,
                rawHex: payload.map { String(format: "%02X", $0) }.joined(),
                ecuAddress: nil,
                quality: DiagnosticMeasurementQualityV1(
                    status: .rawOnly,
                    latencyMilliseconds: nil,
                    ageMilliseconds: 0,
                    sourceFrequencyHz: nil,
                    droppedSamples: 0,
                    notes: ["No verified decode definition is installed for this signal."]
                )
            )
            persist(sample)
            return [sample]
        }

        var results: [DiagnosticSampleV1] = []
        for definition in definitions {
            guard let decoded = Self.decode(payload: payload, definition: definition) else {
                invalidSamples += 1
                continue
            }
            let sample = DiagnosticSampleV1(
                timestamp: Date(),
                monotonicMilliseconds: elapsedMilliseconds(),
                signal: definition.key,
                numericValue: decoded.numeric,
                textValue: decoded.text,
                unit: definition.decode.unit,
                rawHex: payload.map { String(format: "%02X", $0) }.joined(),
                ecuAddress: definition.key.ecuAddress,
                quality: DiagnosticMeasurementQualityV1(
                    status: .good,
                    latencyMilliseconds: nil,
                    ageMilliseconds: 0,
                    sourceFrequencyHz: observedFrequency(for: definition.key),
                    droppedSamples: 0,
                    notes: ["Decoded by \(definition.provenance.name) \(definition.provenance.version)"]
                )
            )
            persist(sample)
            results.append(sample)
        }
        decodedSignalCount = latestSamples.count
        return results
    }

    @discardableResult
    func finishSession(
        dtcs: [String],
        summaryLabel: String,
        supportedPIDs: Set<UInt8>,
        protocolDescription: String,
        adapterDetails: [String: String]
    ) -> URL? {
        guard let directory = sessionDirectory else { return nil }
        closeSamplesFile()
        updateContext(
            vin: vehicleProfile.vin ?? "",
            protocolDescription: protocolDescription,
            adapterDetails: adapterDetails,
            supportedPIDs: supportedPIDs
        )

        let finalCapability = capability ?? DiagnosticCapabilityReportV1(
            discoveredAt: Date(),
            vehicle: vehicleProfile,
            adapter: AdapterCapabilityV1(
                name: "OBDLink MX+",
                firmware: nil,
                hardware: nil,
                manufacturer: "OBD Solutions LLC",
                supportedTransports: [.externalAccessory],
                maximumRequestsPerSecond: nil
            ),
            supportedServices: [],
            supportedSignals: [],
            unsupportedSignals: [],
            rawResponseHeaders: [],
            selectedDataPackIDs: selectedPackIDs,
            warnings: ["Capability discovery was incomplete."]
        )

        let datasets = Self.datasets(in: directory)
        let end = Date()
        let durations = lastSampleAt.compactMap { key, last -> (String, Double)? in
            guard let first = firstSampleAt[key], last > first,
                  let count = sampleCounts[key], count > 1 else { return nil }
            return (key.description, Double(count - 1) / last.timeIntervalSince(first))
        }
        let frequencies = Dictionary(uniqueKeysWithValues: durations)
        let diagnosticCodes = dtcs.map { entry -> DiagnosticCodeRecordV1 in
            let code = entry.split(separator: " ").first.map(String.init) ?? entry
            let status: String
            if entry.contains("[pending]") { status = "pending" }
            else if entry.contains("[permanent]") { status = "permanent" }
            else { status = "stored" }
            return DiagnosticCodeRecordV1(
                code: code,
                status: status,
                ecuAddress: nil,
                descriptionText: OBDDecoder.dtcDescription(code),
                descriptionSource: nil,
                rawHex: ""
            )
        }

        let provenance = registry?.provenance(for: vehicleProfile) ?? []
        let capabilitySignals = Set(finalCapability.supportedSignals)
        let decodedSignals = Set(latestSamples.keys)
        let snapshot = AISnapshotManifestV1(
            schemaVersion: "1.0",
            id: UUID(),
            createdAt: end,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            captureMode: scenarioLabel,
            readOnly: true,
            vehicle: vehicleProfile,
            capability: finalCapability,
            scanPlan: nil,
            scenarios: [
                ScenarioExecutionV1(
                    id: UUID().uuidString,
                    scenarioDefinitionID: scenarioLabel,
                    title: scenarioLabel,
                    startedAt: sessionStartedAt ?? end,
                    endedAt: end,
                    completedPhaseIDs: [],
                    userMarkers: ["fuel=\(fuelMode.rawValue)", summaryLabel],
                    entryConditionsMet: [],
                    entryConditionsMissing: [],
                    notes: []
                )
            ],
            datasets: datasets,
            diagnosticCodes: diagnosticCodes,
            freezeFrames: [],
            mode06Results: [],
            latestSamples: latestSamples.values.sorted { $0.signal.description < $1.signal.description },
            coverage: SignalCoverageSummaryV1(
                discoveredCount: capabilitySignals.count,
                decodedCount: decodedSignals.count,
                rawOnlyCount: rawOnlySignals.count,
                unsupportedCount: 0,
                timedOutCount: timedOutRequests,
                missingRequiredSignals: [],
                missingOptionalSignals: [],
                blockedUnsafeSignals: []
            ),
            quality: DataQualitySummaryV1(
                durationSeconds: end.timeIntervalSince(sessionStartedAt ?? end),
                totalSamples: totalSamples,
                goodSamples: max(0, totalSamples - invalidSamples),
                invalidSamples: invalidSamples,
                timedOutRequests: timedOutRequests,
                droppedSamples: 0,
                clockDiscontinuities: 0,
                averageLatencyMilliseconds: nil,
                observedFrequencyBySignal: frequencies,
                warnings: finalCapability.warnings
            ),
            provenance: provenance,
            analysisQuestion: SnapshotAnalysisQuestionV1(
                symptom: scenarioLabel,
                userDescription: summaryLabel,
                knownDTCs: diagnosticCodes.map(\.code),
                requestedSystems: [],
                constraints: ["read-only acquisition", "do not infer meanings for raw-only identifiers"]
            ),
            privacyNotes: ["VIN may identify the vehicle. Location is not collected by OBD Bridge."]
        )

        do {
            let url = try AISnapshotBuilderV1().write(snapshot, to: directory)
            lastSnapshotURL = url
            status = "AI snapshot saved"
            resetSessionState(keepSnapshot: true)
            return url
        } catch {
            status = "AI snapshot error: \(error.localizedDescription)"
            resetSessionState(keepSnapshot: false)
            return nil
        }
    }

    private func persist(_ sample: DiagnosticSampleV1) {
        latestSamples[sample.signal] = sample
        sampleCounts[sample.signal, default: 0] += 1
        firstSampleAt[sample.signal] = firstSampleAt[sample.signal] ?? sample.timestamp
        lastSampleAt[sample.signal] = sample.timestamp
        totalSamples += 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sample) else { return }
        try? samplesHandle?.write(contentsOf: data)
        try? samplesHandle?.write(contentsOf: Data([0x0A]))
    }

    private func observedFrequency(for key: SignalIdentifierV1) -> Double? {
        guard let first = firstSampleAt[key], let last = lastSampleAt[key], last > first,
              let count = sampleCounts[key], count > 1 else { return nil }
        return Double(count - 1) / last.timeIntervalSince(first)
    }

    private func elapsedMilliseconds() -> Int64 {
        guard let sessionStartedAt else { return 0 }
        return Int64(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }

    private func closeSamplesFile() {
        try? samplesHandle?.synchronize()
        try? samplesHandle?.close()
        samplesHandle = nil
    }

    private func resetSessionState(keepSnapshot: Bool) {
        sessionDirectory = nil
        sessionStartedAt = nil
        scenarioLabel = ""
        if !keepSnapshot { lastSnapshotURL = nil }
    }

    private static func decode(
        payload: [UInt8],
        definition: DiagnosticSignalDefinitionV1
    ) -> (numeric: Double?, text: String?)? {
        let decode = definition.decode
        guard let bitLength = decode.bitLength else {
            if decode.kind == .ascii {
                return (nil, String(bytes: payload, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (nil, payload.map { String(format: "%02X", $0) }.joined())
        }
        let startBit = decode.startBit ?? 0
        guard bitLength > 0, startBit >= 0, startBit + bitLength <= payload.count * 8,
              bitLength <= 63 else { return nil }

        var raw: UInt64 = 0
        if decode.endian == .little, startBit % 8 == 0, bitLength % 8 == 0 {
            let startByte = startBit / 8
            let byteCount = bitLength / 8
            for byte in payload[startByte..<(startByte + byteCount)].reversed() {
                raw = (raw << 8) | UInt64(byte)
            }
        } else {
            for bitOffset in 0..<bitLength {
                let absoluteBit = startBit + bitOffset
                let byte = payload[absoluteBit / 8]
                let bit = (byte >> (7 - (absoluteBit % 8))) & 1
                raw = (raw << 1) | UInt64(bit)
            }
        }

        if let lookup = decode.lookup,
           let value = lookup[String(raw)] ?? lookup[String(format: "0x%X", raw)] {
            return (nil, value)
        }

        let signedValue: Double
        if decode.isSigned == true, bitLength < 64, (raw & (1 << (bitLength - 1))) != 0 {
            signedValue = Double(Int64(raw) - Int64(1 << bitLength))
        } else {
            signedValue = Double(raw)
        }
        let numeric = signedValue * (decode.factor ?? 1) + (decode.offset ?? 0)
        return (numeric, nil)
    }

    private static func resolveVehicle(
        vin: String?,
        protocolDescription: String,
        adapterDetails: [String: String]
    ) -> VehicleProfileV1 {
        let normalizedVIN = vin?.uppercased()
        var make: String?
        var model: String?
        if normalizedVIN?.hasPrefix("JMZ") == true { make = "Mazda" }
        if normalizedVIN?.hasPrefix("JMZCR") == true { model = "5" }

        return VehicleProfileV1(
            vin: normalizedVIN,
            make: make,
            model: model,
            modelYear: normalizedVIN.flatMap(Self.decodeModelYear),
            engine: nil,
            transmission: nil,
            market: nil,
            fuelTypes: [],
            transport: .externalAccessory,
            diagnosticProtocol: applicationProtocol(from: protocolDescription),
            physicalProtocolDescription: protocolDescription.isEmpty ? nil : protocolDescription,
            ecuFingerprints: [
                ECUFingerprintV1(
                    address: "functional",
                    name: nil,
                    responseHeaders: [],
                    calibrationIDs: adapterDetails["calibrationID"].map { [$0] } ?? [],
                    cvns: adapterDetails["cvn"].map { [$0] } ?? [],
                    softwareIDs: [],
                    hardwareIDs: adapterDetails["hardware"].map { [$0] } ?? [],
                    serialNumbers: []
                )
            ]
        )
    }

    private static func decodeModelYear(vin: String) -> Int? {
        guard vin.count == 17 else { return nil }
        let character = vin[vin.index(vin.startIndex, offsetBy: 9)]
        let map: [Character: Int] = [
            "1": 2001, "2": 2002, "3": 2003, "4": 2004, "5": 2005,
            "6": 2006, "7": 2007, "8": 2008, "9": 2009,
            "A": 2010, "B": 2011, "C": 2012, "D": 2013, "E": 2014,
            "F": 2015, "G": 2016, "H": 2017, "J": 2018, "K": 2019,
            "L": 2020, "M": 2021, "N": 2022, "P": 2023, "R": 2024,
            "S": 2025, "T": 2026
        ]
        return map[character]
    }

    private static func applicationProtocol(from text: String) -> DiagnosticApplicationProtocol {
        let value = text.lowercased()
        if value.contains("j1939") { return .j1939 }
        if value.contains("uds") || value.contains("iso 15765") { return .saeJ1979UDS }
        if value.contains("kwp") || value.contains("14230") { return .kwp2000 }
        if value.contains("can") { return .saeJ1979Legacy }
        return value.isEmpty ? .unknown : .proprietary
    }

    private static func requestBudget(protocolDescription: String) -> Double {
        let value = protocolDescription.lowercased()
        if value.contains("kwp") || value.contains("iso 9141") { return 3 }
        if value.contains("can") || value.contains("15765") { return 12 }
        return 6
    }

    private static func datasets(in directory: URL) -> [SnapshotDatasetV1] {
        let fm = FileManager.default
        let names = ["raw-transcript.txt", "events.jsonl", "samples.csv", "professional-samples.jsonl", "summary.json"]
        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return SnapshotDatasetV1(
                relativePath: name,
                mediaType: name.hasSuffix(".csv") ? "text/csv" : (name.hasSuffix(".json") || name.hasSuffix(".jsonl") ? "application/json" : "text/plain"),
                formatVersion: "1.0",
                rowCount: name.hasSuffix(".jsonl") || name.hasSuffix(".csv") ? data.split(separator: 0x0A).count : nil,
                startedAt: nil,
                endedAt: nil,
                checksumSHA256: digest,
                compression: nil,
                descriptionText: name
            )
        }
    }
}
