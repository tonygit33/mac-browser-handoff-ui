import Foundation

struct ProfessionalELMCommand: Hashable {
    let text: String
    let timeout: TimeInterval
    let purpose: String
    let targetFrequencyHz: Double
}

final class OBDAnalysisClient: ObservableObject {
    @Published private(set) var status = "AI analysis not started"
    @Published private(set) var isAnalyzing = false
    @Published private(set) var summary = ""
    @Published private(set) var lastAnalysisURL: URL?
    @Published private(set) var lastError: String?

    private let endpoint: URL

    init(endpoint: URL? = nil) {
        if let endpoint {
            self.endpoint = endpoint
        } else if let configured = Bundle.main.object(forInfoDictionaryKey: "OBDAnalysisEndpoint") as? String,
                  let url = URL(string: configured) {
            self.endpoint = url
        } else {
            self.endpoint = URL(string: "https://project-2yxp4-kache.vercel.app/api/obd-analyze")!
        }
    }

    func analyze(snapshotURL: URL) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        status = "Uploading read-only snapshot…"
        summary = ""
        lastError = nil

        Task {
            do {
                let snapshotData = try Data(contentsOf: snapshotURL)
                guard snapshotData.count <= 4_000_000 else {
                    throw NSError(domain: "OBDAnalysis", code: 413, userInfo: [NSLocalizedDescriptionKey: "AI snapshot exceeds the 4 MB service limit."])
                }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 90
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("OBDBridge-iOS/0.4", forHTTPHeaderField: "User-Agent")
                request.httpBody = snapshotData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "OBDAnalysis", code: -1, userInfo: [NSLocalizedDescriptionKey: "Analysis service returned no HTTP response."])
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw NSError(domain: "OBDAnalysis", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message ?? "Analysis service returned HTTP \(http.statusCode)."])
                }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let resolvedSummary = object?["summary"] as? String ?? "Analysis completed"
                let destination = snapshotURL.deletingLastPathComponent().appendingPathComponent("ai-analysis.json")
                try data.write(to: destination, options: .atomic)

                await MainActor.run {
                    self.isAnalyzing = false
                    self.summary = resolvedSummary
                    self.status = "AI analysis saved"
                    self.lastAnalysisURL = destination
                }
            } catch {
                await MainActor.run {
                    self.isAnalyzing = false
                    self.lastError = error.localizedDescription
                    self.status = "AI analysis failed"
                }
            }
        }
    }
}

extension ProfessionalDiagnosticsRuntime {
    func plannedCommands(for preset: ScanPreset) -> [ProfessionalELMCommand] {
        guard let registry, let capability else { return [] }
        let planner = ProfessionalScanPlannerV1(registry: registry)
        do {
            let plan: DiagnosticReadPlanV1
            if preset == .allSupported {
                plan = try planner.fullSnapshotPlan(capability: capability)
            } else {
                let scenarioID: String
                switch preset {
                case .coldStart:
                    scenarioID = "generic.cold-start"
                case .road:
                    scenarioID = "generic.road-load"
                case .p2188Idle:
                    scenarioID = availableScenarioIDs.contains("mazda5.cr.p2188")
                        ? "mazda5.cr.p2188"
                        : "generic.warm-idle-2500"
                case .warmIdle, .rpm2500:
                    scenarioID = "generic.warm-idle-2500"
                case .allSupported:
                    scenarioID = "full-snapshot"
                }
                plan = try planner.scenarioPlan(scenarioID: scenarioID, capability: capability)
            }
            lastScanPlan = plan
            return plan.reads.compactMap { read in
                guard read.request.service.uppercased() == "01" else { return nil }
                let command = read.request.service + read.request.identifier
                return ProfessionalELMCommand(
                    text: command,
                    timeout: max(2, Double(read.request.timeoutMilliseconds) / 1000),
                    purpose: read.signals.map(\.description).joined(separator: ", "),
                    targetFrequencyHz: read.targetFrequencyHz
                )
            }
        } catch {
            status = "Scan planner fallback: \(error.localizedDescription)"
            return []
        }
    }

    func recordFreezeFrame(command: String, response: String) {
        guard let record = StructuredDiagnosticDecoder.freezeFrame(command: command, response: response) else { return }
        if let index = structuredFreezeFrames.firstIndex(where: { $0.frameNumber == record.frameNumber && $0.samples.first?.signal == record.samples.first?.signal }) {
            structuredFreezeFrames[index] = record
        } else {
            structuredFreezeFrames.append(record)
        }
    }

    func recordMode06(command: String, response: String) {
        for record in StructuredDiagnosticDecoder.mode06(command: command, response: response) {
            let key = "\(record.monitorID):\(record.testID ?? "raw"):\(record.ecuAddress ?? "broadcast")"
            if let index = structuredMode06.firstIndex(where: { "\($0.monitorID):\($0.testID ?? "raw"):\($0.ecuAddress ?? "broadcast")" == key }) {
                structuredMode06[index] = record
            } else {
                structuredMode06.append(record)
            }
        }
    }

    func analyzeLastSnapshot() {
        guard let lastSnapshotURL else {
            status = "Run and save a diagnostic session first."
            return
        }
        analysisClient.analyze(snapshotURL: lastSnapshotURL)
    }
}
