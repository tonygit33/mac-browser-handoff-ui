import Foundation

struct ProfessionalELMCommand: Hashable {
    let text: String
    let timeout: TimeInterval
    let purpose: String
    let targetFrequencyHz: Double
}

struct AnalysisHypothesisSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let probability: Double
    let confidence: Double
    let explanation: String
    let nextReadOnlyTests: [String]
}

final class OBDAnalysisClient: ObservableObject {
    @Published private(set) var status = "Analysis not started"
    @Published private(set) var isAnalyzing = false
    @Published private(set) var summary = ""
    @Published private(set) var topHypotheses: [AnalysisHypothesisSummary] = []
    @Published private(set) var safetyWarnings: [String] = []
    @Published private(set) var engineLabel = ""
    @Published private(set) var detailMessage = ""
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
            self.endpoint = URL(string: "https://project-2yxp4-kache.vercel.app/api/bridge-realtime?command=obd-analyze")!
        }
    }

    func analyze(snapshotURL: URL) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        status = "Uploading read-only snapshot…"
        summary = ""
        topHypotheses = []
        safetyWarnings = []
        engineLabel = ""
        detailMessage = ""
        lastError = nil

        Task {
            do {
                let snapshotData = try Data(contentsOf: snapshotURL)
                guard snapshotData.count <= 4_000_000 else {
                    throw NSError(
                        domain: "OBDAnalysis",
                        code: 413,
                        userInfo: [NSLocalizedDescriptionKey: "AI snapshot exceeds the 4 MB service limit."]
                    )
                }

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 90
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("OBDBridge-iOS/0.4.3", forHTTPHeaderField: "User-Agent")
                request.httpBody = snapshotData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: "OBDAnalysis",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Analysis service returned no HTTP response."]
                    )
                }
                guard (200...299).contains(http.statusCode) else {
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let direct = object?["error"] as? String
                    let nested = (object?["error"] as? [String: Any])?["message"] as? String
                    throw NSError(
                        domain: "OBDAnalysis",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: direct ?? nested ?? "Analysis service returned HTTP \(http.statusCode)."]
                    )
                }

                let destination = snapshotURL.deletingLastPathComponent().appendingPathComponent("ai-analysis.json")
                try data.write(to: destination, options: .atomic)
                let parsed = try Self.parse(data)
                await apply(
                    parsed,
                    url: destination,
                    status: "Cloud analysis saved",
                    detail: "The cloud service analyzed the read-only snapshot."
                )
            } catch {
                let cloudError = error
                do {
                    let local = try LocalOBDAnalysisEngine.analyze(snapshotURL: snapshotURL)
                    let data = try Data(contentsOf: local.url)
                    let parsed = try Self.parse(data)
                    await apply(
                        parsed,
                        url: local.url,
                        status: "On-device expert analysis saved",
                        detail: "Cloud analysis was unavailable; the same snapshot was analyzed locally."
                    )
                } catch {
                    await MainActor.run {
                        self.isAnalyzing = false
                        self.lastError = "Cloud: \(cloudError.localizedDescription) · Local: \(error.localizedDescription)"
                        self.status = "Diagnostic analysis failed"
                    }
                }
            }
        }
    }

    func configureForUITesting() {
        summary = "EVAP purge flow is the leading mechanism"
        topHypotheses = [
            AnalysisHypothesisSummary(
                id: "demo-evap",
                title: "EVAP purge valve leaking at idle",
                probability: 0.72,
                confidence: 0.84,
                explanation: "Negative fuel trims are strongest at warm idle and purge command is elevated.",
                nextReadOnlyTests: ["Compare trims at warm idle and steady 2500 RPM."]
            ),
            AnalysisHypothesisSummary(
                id: "demo-fuel",
                title: "Excess fuel pressure or a leaking injector",
                probability: 0.48,
                confidence: 0.68,
                explanation: "A mechanical over-fuelling source remains possible and needs pressure evidence.",
                nextReadOnlyTests: ["Capture rail pressure and compare hot restart behavior."]
            )
        ]
        safetyWarnings = []
        engineLabel = "On-device rules"
        status = "On-device expert analysis saved"
        detailMessage = "Demo evidence for automated UX testing."
        lastError = nil
    }

    private struct ParsedAnalysis {
        let summary: String
        let hypotheses: [AnalysisHypothesisSummary]
        let warnings: [String]
        let engineLabel: String
    }

    private static func parse(_ data: Data) throws -> ParsedAnalysis {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "OBDAnalysis",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Analysis response is not a JSON object."]
            )
        }

        let summary = object["summary"] as? String ?? "Analysis completed"
        let rows = object["hypotheses"] as? [[String: Any]] ?? []
        let hypotheses = rows.compactMap { row -> AnalysisHypothesisSummary? in
            guard let title = row["title"] as? String else { return nil }
            let identifier = row["id"] as? String ?? UUID().uuidString
            let probability = (row["probability"] as? NSNumber)?.doubleValue ?? 0
            let confidence = (row["confidence"] as? NSNumber)?.doubleValue ?? 0
            let explanation = row["explanation"] as? String ?? ""
            let tests = row["nextReadOnlyTests"] as? [String] ?? []
            return AnalysisHypothesisSummary(
                id: identifier,
                title: title,
                probability: max(0, min(1, probability)),
                confidence: max(0, min(1, confidence)),
                explanation: explanation,
                nextReadOnlyTests: tests
            )
        }

        let warnings = object["urgentSafetyAdvice"] as? [String] ?? []
        let engine = object["engine"] as? String ?? ""
        let model = object["modelIdentifier"] as? String ?? ""
        let label: String
        switch engine.lowercased() {
        case "openai": label = "Cloud AI"
        case "rules-on-device": label = "On-device rules"
        case "rules": label = "Expert rules"
        default: label = model.isEmpty ? "Evidence analysis" : model
        }

        return ParsedAnalysis(summary: summary, hypotheses: hypotheses, warnings: warnings, engineLabel: label)
    }

    @MainActor
    private func apply(_ parsed: ParsedAnalysis, url: URL, status: String, detail: String) {
        isAnalyzing = false
        summary = parsed.summary
        topHypotheses = parsed.hypotheses
        safetyWarnings = parsed.warnings
        engineLabel = parsed.engineLabel
        detailMessage = detail
        lastAnalysisURL = url
        lastError = nil
        self.status = status
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
                    targetFrequencyHz: max(0.05, read.targetFrequencyHz)
                )
            }
        } catch {
            status = "Scan planner fallback: \(error.localizedDescription)"
            return []
        }
    }

    func recordFreezeFrame(command: String, response: String) {
        guard let record = StructuredDiagnosticDecoder.freezeFrame(command: command, response: response) else { return }
        if let index = structuredFreezeFrames.firstIndex(where: {
            $0.frameNumber == record.frameNumber && $0.samples.first?.signal == record.samples.first?.signal
        }) {
            structuredFreezeFrames[index] = record
        } else {
            structuredFreezeFrames.append(record)
        }
    }

    func recordMode06(command: String, response: String) {
        for record in StructuredDiagnosticDecoder.mode06(command: command, response: response) {
            let key = "\(record.monitorID):\(record.testID ?? "raw"):\(record.ecuAddress ?? "broadcast")"
            if let index = structuredMode06.firstIndex(where: {
                "\($0.monitorID):\($0.testID ?? "raw"):\($0.ecuAddress ?? "broadcast")" == key
            }) {
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
