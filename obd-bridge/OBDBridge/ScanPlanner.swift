import Foundation

enum SignalSamplingTierV1: String, Codable, CaseIterable {
    case fast
    case medium
    case slow
    case oneShot
}

struct PlannedDiagnosticReadV1: Codable, Hashable, Identifiable {
    var id: String {
        [phaseID, request.header, request.service, request.identifier]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")
    }

    /// Every signal decoded from this single transport request.
    let signals: [SignalIdentifierV1]
    let request: DiagnosticRequestDefinitionV1
    let phaseID: String
    let samplingTier: SignalSamplingTierV1
    let targetFrequencyHz: Double
    let priority: Int
    let required: Bool
    let safety: DiagnosticSafetyClass
    let rationale: String?
}

struct DiagnosticReadPlanV1: Codable, Hashable {
    let schemaVersion: String
    let createdAt: Date
    let scenarioID: String
    let vehicle: VehicleProfileV1
    let selectedPackIDs: [String]
    let reads: [PlannedDiagnosticReadV1]
    let missingRequiredSignals: [SignalIdentifierV1]
    let missingOptionalSignals: [SignalIdentifierV1]
    let blockedSignals: [SignalIdentifierV1]
    let estimatedRequestsPerSecond: Double
    let warnings: [String]
}

enum ProfessionalScanPlannerError: LocalizedError {
    case scenarioNotFound(String)
    case noReadableSignals

    var errorDescription: String? {
        switch self {
        case let .scenarioNotFound(id): return "Diagnostic scenario not found: \(id)"
        case .noReadableSignals: return "No safe readable signals are available for this vehicle."
        }
    }
}

/// Builds deterministic, read-only scan schedules from vehicle capabilities and data packs.
/// It does not send commands; transport implementations execute the resulting plan.
struct ProfessionalScanPlannerV1 {
    private static let allowedLegacyReadServices: Set<String> = ["01", "02", "03", "06", "07", "09", "0A"]
    private static let allowedUDSReadServices: Set<String> = ["19", "22", "1A"]

    let registry: SignalRegistryV1

    func scenarioPlan(
        scenarioID: String,
        capability: DiagnosticCapabilityReportV1,
        requestBudgetPerSecond: Double? = nil
    ) throws -> DiagnosticReadPlanV1 {
        guard let scenario = registry.scenarios(for: capability.vehicle).first(where: { $0.id == scenarioID }) else {
            throw ProfessionalScanPlannerError.scenarioNotFound(scenarioID)
        }

        let selectedPacks = registry.matchingPacks(for: capability.vehicle).map(\.pack.id)
        var candidates: [PlannedDiagnosticReadV1] = []
        var missingRequired: [SignalIdentifierV1] = []
        var missingOptional: [SignalIdentifierV1] = []
        var blocked: [SignalIdentifierV1] = []

        for phase in scenario.phases {
            for requirement in phase.signals {
                let resolved = registry.resolvedDefinitions(for: requirement.signal, vehicle: capability.vehicle)
                guard !resolved.isEmpty else {
                    if requirement.required {
                        missingRequired.append(requirement.signal)
                    } else {
                        missingOptional.append(requirement.signal)
                    }
                    continue
                }

                let safe = resolved.filter(Self.isSafeRead)
                if safe.isEmpty {
                    blocked.append(requirement.signal)
                    continue
                }

                let available = safe.filter { capability.supports($0.key) }
                guard !available.isEmpty else {
                    if requirement.required {
                        missingRequired.append(requirement.signal)
                    } else {
                        missingOptional.append(requirement.signal)
                    }
                    continue
                }

                for definition in available {
                    let requestedRate = requirement.targetFrequencyHz
                        ?? definition.preferredFrequencyHz
                        ?? Self.defaultFrequency(for: definition.category)
                    let cappedRate = min(requestedRate, definition.maximumFrequencyHz ?? requestedRate)
                    candidates.append(
                        PlannedDiagnosticReadV1(
                            signals: [definition.key],
                            request: definition.request,
                            phaseID: phase.id,
                            samplingTier: Self.tier(for: cappedRate, phaseDuration: phase.minimumDurationSeconds),
                            targetFrequencyHz: max(0.05, cappedRate),
                            priority: requirement.required ? 100 : Self.priority(for: definition.category),
                            required: requirement.required,
                            safety: definition.safety,
                            rationale: requirement.rationale
                        )
                    )
                }
            }
        }

        let coalesced = Self.coalesce(candidates)
        guard !coalesced.isEmpty else { throw ProfessionalScanPlannerError.noReadableSignals }

        let budget = max(
            1,
            requestBudgetPerSecond
                ?? capability.adapter.maximumRequestsPerSecond
                ?? Self.defaultAdapterBudget(for: capability.vehicle.diagnosticProtocol)
        )
        let balanced = Self.balance(reads: coalesced, budget: budget)
        var warnings: [String] = []
        if !missingRequired.isEmpty {
            warnings.append("Some required signals are unavailable; AI confidence must be reduced.")
        }
        if !blocked.isEmpty {
            warnings.append("Unsafe or non-read-only signal definitions were excluded from the plan.")
        }

        return DiagnosticReadPlanV1(
            schemaVersion: "1.0",
            createdAt: Date(),
            scenarioID: scenario.id,
            vehicle: capability.vehicle,
            selectedPackIDs: selectedPacks,
            reads: balanced,
            missingRequiredSignals: Self.unique(missingRequired),
            missingOptionalSignals: Self.unique(missingOptional),
            blockedSignals: Self.unique(blocked),
            estimatedRequestsPerSecond: balanced.reduce(0) { $0 + $1.targetFrequencyHz },
            warnings: warnings
        )
    }

    /// Produces a one-time snapshot plan for every verified signal the vehicle reports as supported.
    func fullSnapshotPlan(
        capability: DiagnosticCapabilityReportV1,
        requestBudgetPerSecond: Double? = nil
    ) throws -> DiagnosticReadPlanV1 {
        let selectedPacks = registry.matchingPacks(for: capability.vehicle).map(\.pack.id)
        var blocked: [SignalIdentifierV1] = []
        var candidates: [PlannedDiagnosticReadV1] = []

        for definition in registry.signalDefinitions(for: capability.vehicle) {
            guard capability.supports(definition.key) else { continue }
            guard Self.isSafeRead(definition) else {
                blocked.append(definition.key)
                continue
            }
            candidates.append(
                PlannedDiagnosticReadV1(
                    signals: [definition.key],
                    request: definition.request,
                    phaseID: "full-snapshot",
                    samplingTier: .oneShot,
                    targetFrequencyHz: 0.1,
                    priority: Self.priority(for: definition.category),
                    required: false,
                    safety: definition.safety,
                    rationale: "Complete verified signal snapshot"
                )
            )
        }

        let coalesced = Self.coalesce(candidates)
        guard !coalesced.isEmpty else { throw ProfessionalScanPlannerError.noReadableSignals }

        let budget = max(
            1,
            requestBudgetPerSecond
                ?? capability.adapter.maximumRequestsPerSecond
                ?? Self.defaultAdapterBudget(for: capability.vehicle.diagnosticProtocol)
        )
        let balanced = Self.balance(reads: coalesced, budget: budget)

        return DiagnosticReadPlanV1(
            schemaVersion: "1.0",
            createdAt: Date(),
            scenarioID: "full-snapshot",
            vehicle: capability.vehicle,
            selectedPackIDs: selectedPacks,
            reads: balanced,
            missingRequiredSignals: [],
            missingOptionalSignals: [],
            blockedSignals: Self.unique(blocked),
            estimatedRequestsPerSecond: balanced.reduce(0) { $0 + $1.targetFrequencyHz },
            warnings: blocked.isEmpty ? [] : ["Write-capable or unverified definitions were excluded."]
        )
    }

    private struct RequestGroupKey: Hashable {
        let phaseID: String
        let service: String
        let identifier: String
        let header: String?
        let session: String?
        let subfunction: String?
    }

    /// Coalesces multiple decoded signals into one physical PID/DID/CAN request.
    private static func coalesce(_ reads: [PlannedDiagnosticReadV1]) -> [PlannedDiagnosticReadV1] {
        let groups = Dictionary(grouping: reads) { read in
            RequestGroupKey(
                phaseID: read.phaseID,
                service: read.request.service,
                identifier: read.request.identifier,
                header: read.request.header,
                session: read.request.session,
                subfunction: read.request.subfunction
            )
        }

        return groups.values.map { group in
            let first = group[0]
            let signals = unique(group.flatMap(\.signals))
            let rationales = Array(Set(group.compactMap(\.rationale))).sorted()
            let targetRate = group.map(\.targetFrequencyHz).max() ?? first.targetFrequencyHz
            return PlannedDiagnosticReadV1(
                signals: signals,
                request: first.request,
                phaseID: first.phaseID,
                samplingTier: group.map(\.samplingTier).contains(.fast) ? .fast : first.samplingTier,
                targetFrequencyHz: targetRate,
                priority: group.map(\.priority).max() ?? first.priority,
                required: group.contains(where: { $0.required }),
                safety: group.allSatisfy { $0.safety == .passive } ? .passive : .readOnly,
                rationale: rationales.isEmpty ? nil : rationales.joined(separator: "; ")
            )
        }
        .sorted(by: Self.readSort)
    }

    private static func isSafeRead(_ definition: DiagnosticSignalDefinitionV1) -> Bool {
        guard definition.safety == .passive || definition.safety == .readOnly else { return false }
        let service = definition.request.service.uppercased()
        switch definition.key.namespace.lowercased() {
        case "sae", "j1979": return allowedLegacyReadServices.contains(service)
        case "uds", "odx": return allowedUDSReadServices.contains(service)
        case "can", "dbc": return definition.safety == .passive
        default: return definition.safety == .passive || definition.safety == .readOnly
        }
    }

    private static func balance(reads: [PlannedDiagnosticReadV1], budget: Double) -> [PlannedDiagnosticReadV1] {
        let total = reads.reduce(0) { $0 + $1.targetFrequencyHz }
        guard total > budget else { return reads.sorted(by: readSort) }

        let requiredRate = reads.filter(\.required).reduce(0) { $0 + $1.targetFrequencyHz }
        let optionalRate = max(0.001, total - requiredRate)
        let optionalBudget = max(0, budget - min(requiredRate, budget * 0.8))
        let scale = min(1, optionalBudget / optionalRate)

        return reads.map { read in
            let newRate: Double
            if read.required {
                let requiredScale = requiredRate > budget ? budget / requiredRate : 1
                newRate = max(0.1, read.targetFrequencyHz * requiredScale)
            } else {
                newRate = max(0.05, read.targetFrequencyHz * scale)
            }
            return PlannedDiagnosticReadV1(
                signals: read.signals,
                request: read.request,
                phaseID: read.phaseID,
                samplingTier: tier(for: newRate, phaseDuration: 60),
                targetFrequencyHz: newRate,
                priority: read.priority,
                required: read.required,
                safety: read.safety,
                rationale: read.rationale
            )
        }
        .sorted(by: readSort)
    }

    private static func readSort(_ lhs: PlannedDiagnosticReadV1, _ rhs: PlannedDiagnosticReadV1) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }

    private static func defaultAdapterBudget(for protocolName: DiagnosticApplicationProtocol) -> Double {
        switch protocolName {
        case .kwp2000: return 3
        case .saeJ1979Legacy: return 8
        case .saeJ1979UDS, .uds: return 12
        case .j1939, .rawCAN: return 20
        case .doip: return 30
        case .proprietary, .unknown: return 5
        }
    }

    private static func defaultFrequency(for category: String) -> Double {
        switch category.lowercased() {
        case "engine-speed", "airflow", "fuel-trim", "oxygen", "throttle", "pedal": return 5
        case "pressure", "temperature", "load", "vehicle-speed": return 2
        case "voltage", "readiness", "identity", "dtc": return 0.2
        default: return 1
        }
    }

    private static func priority(for category: String) -> Int {
        switch category.lowercased() {
        case "dtc", "identity", "readiness": return 95
        case "fuel-trim", "oxygen", "engine-speed", "airflow": return 90
        case "pressure", "temperature", "throttle", "pedal": return 80
        default: return 50
        }
    }

    private static func tier(for frequency: Double, phaseDuration: Double) -> SignalSamplingTierV1 {
        if phaseDuration <= 1 || frequency <= 0.11 { return .oneShot }
        if frequency >= 4 { return .fast }
        if frequency >= 1 { return .medium }
        return .slow
    }

    private static func unique(_ values: [SignalIdentifierV1]) -> [SignalIdentifierV1] {
        Array(Set(values)).sorted { $0.description < $1.description }
    }
}
