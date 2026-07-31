from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing patch target: {label}")
    return text.replace(old, new, 1)


runtime = Path("obd-bridge/OBDBridge/ProfessionalDiagnosticsRuntime.swift")
text = runtime.read_text()
text = replace_once(
    text,
    '@Published private(set) var status = "Loading diagnostic data packs…"',
    '@Published var status = "Loading diagnostic data packs…"',
    "runtime status access",
)
text = replace_once(
    text,
    '''    @Published private(set) var lastSnapshotURL: URL?\n\n    private(set) var vehicleProfile''',
    '''    @Published private(set) var lastSnapshotURL: URL?\n\n    let analysisClient = OBDAnalysisClient()\n    var structuredFreezeFrames: [FreezeFrameRecordV1] = []\n    var structuredMode06: [Mode06RecordV1] = []\n    var lastScanPlan: DiagnosticReadPlanV1?\n\n    private(set) var vehicleProfile''',
    "runtime completion properties",
)
text = text.replace("    private var registry: SignalRegistryV1?", "    var registry: SignalRegistryV1?")
text = text.replace("    private var capability: DiagnosticCapabilityReportV1?", "    var capability: DiagnosticCapabilityReportV1?")
text = text.replace("    private var sessionDirectory: URL?", "    var sessionDirectory: URL?")
text = replace_once(
    text,
    '''        rawOnlySignals.removeAll()\n        lastSnapshotURL = nil\n''',
    '''        rawOnlySignals.removeAll()\n        structuredFreezeFrames.removeAll()\n        structuredMode06.removeAll()\n        lastScanPlan = nil\n        lastSnapshotURL = nil\n''',
    "runtime reset structured data",
)
text = replace_once(text, "            scanPlan: nil,", "            scanPlan: lastScanPlan,", "snapshot scan plan")
text = replace_once(text, "            freezeFrames: [],", "            freezeFrames: structuredFreezeFrames,", "snapshot freeze frames")
text = replace_once(text, "            mode06Results: [],", "            mode06Results: structuredMode06,", "snapshot mode 06")
runtime.write_text(text)

bridge = Path("obd-bridge/OBDBridge/AccessoryBridge.swift")
text = bridge.read_text()
text = replace_once(
    text,
    '''    var exportURLs: [URL] { recorder.lastExportURLs }\n''',
    '''    var exportURLs: [URL] {\n        var urls = recorder.lastExportURLs\n        if let snapshot = professional.lastSnapshotURL {\n            urls.append(snapshot)\n            let directory = snapshot.deletingLastPathComponent()\n            for name in ["professional-samples.jsonl", "ai-analysis.json"] {\n                let url = directory.appendingPathComponent(name)\n                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }\n            }\n        }\n        if let analysis = professional.analysisClient.lastAnalysisURL { urls.append(analysis) }\n        return Array(Dictionary(grouping: urls, by: \\.path).values.compactMap(\\.first))\n    }\n''',
    "bridge export URLs",
)
text = replace_once(
    text,
    '''        if upper.hasPrefix("06"), upper.count >= 4,\n           let mid = UInt8(upper.dropFirst(2).prefix(2), radix: 16),\n           mid % 0x20 == 0 {\n            supportedMIDs.formUnion(OBDDecoder.supportedIDs(responseService: 0x46, base: mid, response: response))\n        }\n''',
    '''        if upper.hasPrefix("02"), upper.count >= 6 {\n            professional.recordFreezeFrame(command: upper, response: response)\n        }\n\n        if upper.hasPrefix("06"), upper.count >= 4,\n           let mid = UInt8(upper.dropFirst(2).prefix(2), radix: 16) {\n            if mid % 0x20 == 0 {\n                supportedMIDs.formUnion(OBDDecoder.supportedIDs(responseService: 0x46, base: mid, response: response))\n            } else {\n                professional.recordMode06(command: upper, response: response)\n            }\n        }\n''',
    "bridge structured mode 02 and 06",
)
legacy_cycle = '''        let requested: [UInt8]\n        if preset == .allSupported, !supportedPIDs.isEmpty {\n            requested = supportedPIDs.filter { $0 % 0x20 != 0 }.sorted()\n        } else {\n            requested = preset.preferredPIDs\n        }\n        let filtered = requested.filter { supportedPIDs.isEmpty || supportedPIDs.contains($0) }\n        var commands = filtered.map {\n            q(String(format: "01%02X", $0), 8, PIDCatalog.definitions[$0]?.name ?? "Live PID")\n        }\n'''
planned_cycle = '''        let planned = professional.plannedCommands(for: preset)\n        var commands: [QueuedCommand]\n        if !planned.isEmpty {\n            commands = planned.map { q($0.text, $0.timeout, $0.purpose) }\n        } else {\n            let requested: [UInt8]\n            if preset == .allSupported, !supportedPIDs.isEmpty {\n                requested = supportedPIDs.filter { $0 % 0x20 != 0 }.sorted()\n            } else {\n                requested = preset.preferredPIDs\n            }\n            let filtered = requested.filter { supportedPIDs.isEmpty || supportedPIDs.contains($0) }\n            commands = filtered.map {\n                q(String(format: "01%02X", $0), 8, PIDCatalog.definitions[$0]?.name ?? "Live PID")\n            }\n        }\n'''
text = replace_once(text, legacy_cycle, planned_cycle, "professional continuous plan")
bridge.write_text(text)

content = Path("obd-bridge/OBDBridge/ContentView.swift")
text = content.read_text()
text = replace_once(
    text,
    '''                    if bridge.isLogging || bridge.isBusy {\n                        progressCard\n                    }\n''',
    '''                    if bridge.isLogging || bridge.isBusy {\n                        progressCard\n                    }\n                    ProfessionalRuntimeCard(runtime: bridge.professional)\n''',
    "professional runtime card placement",
)
card = r'''

struct ProfessionalRuntimeCard: View {
    @ObservedObject var runtime: ProfessionalDiagnosticsRuntime
    @ObservedObject private var analysis: OBDAnalysisClient

    init(runtime: ProfessionalDiagnosticsRuntime) {
        self.runtime = runtime
        self.analysis = runtime.analysisClient
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Professional diagnostics", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Text("\(runtime.decodedSignalCount) signals")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(runtime.vehicleDisplayName)
                .font(.subheadline.weight(.semibold))
            Text(runtime.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !runtime.selectedPackIDs.isEmpty {
                Text("Packs: \(runtime.selectedPackIDs.joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .font(.subheadline.weight(.semibold))
            }
            if let error = analysis.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(analysis.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                runtime.analyzeLastSnapshot()
            } label: {
                Label(analysis.isAnalyzing ? "Analyzing…" : "Analyze latest AI snapshot", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runtime.lastSnapshotURL == nil || analysis.isAnalyzing)
            Text("The service analyzes evidence only. It cannot clear codes, actuate components, code modules or write to an ECU.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}
'''
text = replace_once(text, "\nstruct ActivityView: UIViewControllerRepresentable {", card + "\nstruct ActivityView: UIViewControllerRepresentable {", "professional runtime card definition")
content.write_text(text)

project = Path("obd-bridge/project.yml")
text = project.read_text()
text = text.replace('CFBundleShortVersionString: "0.3.1"', 'CFBundleShortVersionString: "0.4.0"')
text = text.replace('CFBundleVersion: "5"', 'CFBundleVersion: "6"')
text = text.replace('MARKETING_VERSION: "0.3.1"', 'MARKETING_VERSION: "0.4.0"')
text = text.replace('CURRENT_PROJECT_VERSION: "5"', 'CURRENT_PROJECT_VERSION: "6"')
text = replace_once(
    text,
    '        NSBluetoothAlwaysUsageDescription:',
    '        OBDAnalysisEndpoint: https://project-2yxp4-kache.vercel.app/api/obd-analyze\n        NSBluetoothAlwaysUsageDescription:',
    "analysis endpoint project setting",
)
project.write_text(text)

plist = Path("obd-bridge/OBDBridge/Info.plist")
text = plist.read_text()
text = text.replace("<string>0.3.1</string>", "<string>0.4.0</string>")
text = text.replace("<string>5</string>", "<string>6</string>", 1)
text = replace_once(
    text,
    "    <key>NSBluetoothAlwaysUsageDescription</key>",
    "    <key>OBDAnalysisEndpoint</key>\n    <string>https://project-2yxp4-kache.vercel.app/api/obd-analyze</string>\n    <key>NSBluetoothAlwaysUsageDescription</key>",
    "analysis endpoint plist",
)
plist.write_text(text)

Path(__file__).unlink()
