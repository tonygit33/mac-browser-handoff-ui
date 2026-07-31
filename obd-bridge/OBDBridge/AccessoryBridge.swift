
import Foundation
import ExternalAccessory

struct AccessorySummary: Identifiable, Hashable {
    let id: Int
    let name: String
    let model: String
    let manufacturer: String
    let protocols: [String]
}

private struct QueuedCommand: Identifiable {
    let id = UUID()
    let text: String
    let timeout: TimeInterval
    let purpose: String
}

private enum BridgeWorkflow {
    case none
    case deepDiscovery
    case deepSnapshot
    case continuous
}

final class AccessoryBridge: NSObject, ObservableObject, StreamDelegate {
    static let obdLinkProtocol = "com.obdlink"

    @Published private(set) var accessories: [AccessorySummary] = []
    @Published private(set) var status = "Looking for paired OBDLink MX+…"
    @Published private(set) var connectedName: String?
    @Published private(set) var log = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var progressText = ""
    @Published private(set) var latestValues: [String:String] = [:]
    @Published private(set) var dtcs: [String] = []
    @Published private(set) var vin = ""
    @Published private(set) var protocolDescription = ""
    @Published private(set) var supportedPIDCount = 0
    @Published private(set) var activeScenario = ""
    @Published private(set) var isLogging = false
    @Published private(set) var isConnecting = false

    let recorder = DiagnosticSessionRecorder()
    let professional = ProfessionalDiagnosticsRuntime()

    var exportURLs: [URL] {
        var urls = recorder.lastExportURLs
        if let snapshot = professional.lastSnapshotURL {
            urls.append(snapshot)
            let directory = snapshot.deletingLastPathComponent()
            for name in ["professional-samples.jsonl", "ai-analysis.json"] {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            }
        }
        if let analysis = professional.analysisClient.lastAnalysisURL { urls.append(analysis) }
        return Array(Dictionary(grouping: urls, by: \.path).values.compactMap(\.first))
    }

    private var accessory: EAAccessory?
    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var pendingWrites: [Data] = []

    private var commandQueue: [QueuedCommand] = []
    private var activeCommand: QueuedCommand?
    private var activeBuffer = ""
    private var timeoutWorkItem: DispatchWorkItem?
    private var nextCycleWorkItem: DispatchWorkItem?
    private var workflow: BridgeWorkflow = .none
    private var supportedPIDs = Set<UInt8>()
    private var supportedMIDs = Set<UInt8>()
    private var planTotal = 0
    private var planCompleted = 0
    private var continuousPreset: ScanPreset?
    private var continuousCycleCount = 0
    private var currentFuelMode: FuelMode = .unknown
    private var adapterDetails: [String:String] = [:]
    private var inputReady = false
    private var outputReady = false
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var promptRecoveryWorkItem: DispatchWorkItem?
    private var discardingUntilPrompt = false
    private var continuousNextDue: [String: Date] = [:]
    private var lastContinuousHealthAt: Date?
    private let demoMode = ProcessInfo.processInfo.arguments.contains("--ui-testing-demo")

    override init() {
        super.init()
        if demoMode {
            configureDemoState()
            return
        }
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoriesChanged),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoriesChanged),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
        refreshAccessories()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if !demoMode {
            EAAccessoryManager.shared().unregisterForLocalNotifications()
        }
        close()
    }

    @objc private func accessoriesChanged() {
        refreshAccessories()
        if accessory != nil,
           !EAAccessoryManager.shared().connectedAccessories.contains(where: { $0.connectionID == accessory?.connectionID }) {
            appendLog("Accessory disconnected")
            close()
        }
    }

    func refreshAccessories() {
        if demoMode { return }
        let found = EAAccessoryManager.shared().connectedAccessories
        accessories = found.map {
            AccessorySummary(
                id: $0.connectionID,
                name: $0.name,
                model: $0.modelNumber,
                manufacturer: $0.manufacturer,
                protocols: $0.protocolStrings
            )
        }

        if found.isEmpty {
            status = "No connected External Accessory found"
        } else if isConnected {
            status = "Connected to \(connectedName ?? "OBDLink MX+")"
        } else if found.contains(where: { $0.protocolStrings.contains(Self.obdLinkProtocol) }) {
            status = "OBDLink found — ready to connect"
        } else {
            status = "Accessory found, but com.obdlink is not advertised"
        }
    }

    func connect() {
        guard !isConnecting else { return }
        close(preserveStatus: true)
        refreshAccessories()

        guard let selected = EAAccessoryManager.shared().connectedAccessories.first(where: {
            $0.protocolStrings.contains(Self.obdLinkProtocol)
        }) else {
            appendLog("No accessory advertising protocol \(Self.obdLinkProtocol)")
            status = "OBDLink protocol not found"
            return
        }

        guard let newSession = EASession(accessory: selected, forProtocol: Self.obdLinkProtocol) else {
            appendLog("EASession could not be created for \(selected.name)")
            status = "EASession rejected"
            return
        }

        accessory = selected
        session = newSession
        inputStream = newSession.inputStream
        outputStream = newSession.outputStream
        inputReady = false
        outputReady = false
        isConnecting = true

        inputStream?.delegate = self
        outputStream?.delegate = self
        inputStream?.schedule(in: .main, forMode: .common)
        outputStream?.schedule(in: .main, forMode: .common)
        inputStream?.open()
        outputStream?.open()

        connectedName = selected.name
        status = "Opening OBDLink session…"
        appendLog("Opening \(selected.name) [\(selected.modelNumber)]")
        appendLog("Protocols: \(selected.protocolStrings.joined(separator: ", "))")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isConnecting, !self.isConnected else { return }
            self.failConnection("Connection timed out")
        }
        connectionTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func close(preserveStatus: Bool = false) {
        stopWorkflow(save: true)
        timeoutWorkItem?.cancel()
        nextCycleWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        promptRecoveryWorkItem?.cancel()
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        inputStream?.delegate = nil
        outputStream?.delegate = nil
        inputStream = nil
        outputStream = nil
        session = nil
        accessory = nil
        pendingWrites.removeAll()
        commandQueue.removeAll()
        activeCommand = nil
        activeBuffer = ""
        connectedName = nil
        isConnected = false
        isConnecting = false
        inputReady = false
        outputReady = false
        discardingUntilPrompt = false
        if !preserveStatus { status = "Disconnected" }
    }

    func clearLog() {
        log = ""
    }

    func send(_ rawCommand: String) {
        let command = normalized(rawCommand)
        guard !command.isEmpty else { return }
        guard isConnected else {
            appendLog("Not connected; command ignored: \(command)")
            return
        }
        guard isSafeReadOnlyManualCommand(command) else {
            appendLog("BLOCKED unsafe or unknown command: \(command)")
            appendLog("Manual terminal allows read-only OBD modes 01, 02, 03, 06, 07, 09 and 0A only.")
            return
        }
        enqueue([QueuedCommand(text: command, timeout: 15, purpose: "Manual read-only command")])
    }

    func runDeepReadOnlyScan(fuelMode: FuelMode) {
        guard isConnected, workflow == .none, !isBusy else {
            appendLog("Connect first and wait for the current operation to finish.")
            return
        }

        currentFuelMode = fuelMode
        supportedPIDs.removeAll()
        supportedMIDs.removeAll()
        latestValues.removeAll()
        dtcs.removeAll()
        adapterDetails.removeAll()
        protocolDescription = ""
        activeScenario = "Deep read-only scan"
        isLogging = true
        workflow = .deepDiscovery
        planCompleted = 0

        recorder.begin(
            label: "Deep-read-only-scan",
            fuelMode: fuelMode,
            metadata: [
                "vehicle": "Auto-detect",
                "adapter": connectedName ?? "OBDLink MX+",
                "appMode": "read-only",
                "dataPackMode": "automatic verified packs"
            ]
        )
        professional.beginSession(directory: recorder.currentDirectory, fuelMode: fuelMode, scenario: activeScenario)
        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)

        var commands: [QueuedCommand] = [
            q("ATZ", 5, "Reset adapter"),
            q("ATE0", 3, "Disable echo"),
            q("ATL0", 3, "Disable linefeeds"),
            q("ATS1", 3, "Show spaces"),
            q("ATH1", 3, "Show ECU headers"),
            q("ATAL", 3, "Allow long messages"),
            q("ATSP0", 12, "Auto-detect vehicle protocol"),
            q("ATI", 3, "ELM compatibility ID"),
            q("STI", 3, "OBDLink firmware"),
            q("STDI", 3, "OBDLink hardware"),
            q("STIX", 3, "Extended firmware"),
            q("STDIX", 4, "Extended adapter information"),
            q("STMFR", 3, "Adapter manufacturer"),
            q("ATRV", 3, "Vehicle supply voltage"),
            q("ATDP", 3, "Protocol name"),
            q("ATDPN", 3, "Protocol number"),
            q("STPR", 3, "ST protocol number"),
            q("STPRS", 3, "ST protocol name"),
            q("STPBRR", 3, "Actual protocol baud rate")
        ]

        for base in stride(from: 0, through: 0xE0, by: 0x20) {
            commands.append(q(String(format: "01%02X", base), 12, "Discover SAE PIDs"))
        }
        commands += [
            q("0101", 8, "Readiness and MIL status"),
            q("0102", 8, "DTC that stored freeze frame"),
            q("03", 12, "Stored emission DTCs"),
            q("07", 12, "Pending emission DTCs"),
            q("0A", 12, "Permanent emission DTCs"),
            q("020000", 12, "Freeze-frame supported PIDs"),
            q("020200", 12, "Freeze-frame DTC"),
            q("0900", 10, "Vehicle information support"),
            q("0902", 18, "VIN"),
            q("0904", 18, "Calibration IDs"),
            q("0906", 18, "Calibration verification numbers"),
            q("090A", 18, "ECU names")
        ]
        for base in stride(from: 0, through: 0xE0, by: 0x20) {
            commands.append(q(String(format: "06%02X", base), 12, "Discover Mode 06 monitor IDs"))
        }

        planTotal = commands.count
        progress = 0
        progressText = "Starting discovery…"
        enqueue(commands)
    }

    func startContinuousLogging(preset: ScanPreset, fuelMode: FuelMode) {
        guard isConnected, workflow == .none, !isBusy else {
            appendLog("Connect first and wait for the current operation to finish.")
            return
        }
        currentFuelMode = fuelMode
        continuousPreset = preset
        continuousCycleCount = 0
        continuousNextDue.removeAll()
        lastContinuousHealthAt = nil
        workflow = .continuous
        activeScenario = preset.rawValue
        isLogging = true
        planCompleted = 0
        planTotal = 0
        progress = 0
        progressText = "Continuous logging"

        recorder.begin(
            label: preset.rawValue,
            fuelMode: fuelMode,
            metadata: [
                "vehicle": "Auto-detect",
                "adapter": connectedName ?? "OBDLink MX+",
                "appMode": "read-only continuous",
                "instructions": preset.instructions
            ]
        )
        professional.beginSession(directory: recorder.currentDirectory, fuelMode: fuelMode, scenario: activeScenario)
        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)
        recorder.marker("User-selected test: \(preset.rawValue)")
        let setup = [
            q("ATE0", 3, "Disable echo"),
            q("ATL0", 3, "Disable linefeeds"),
            q("ATS1", 3, "Show spaces"),
            q("ATH1", 3, "Show ECU headers"),
            q("ATAL", 3, "Allow long messages"),
            q("ATSP0", 12, "Auto-detect vehicle protocol")
        ]
        planTotal = setup.count
        enqueue(setup)
    }

    func stopLogging() {
        guard workflow != .none || recorder.currentDirectory != nil else { return }
        stopWorkflow(save: true)
        status = isConnected ? "Connected to \(connectedName ?? "OBDLink MX+")" : "Disconnected"
    }

    func setFuelMode(_ mode: FuelMode) {
        currentFuelMode = mode
        recorder.setFuelMode(mode)
        professional.setFuelMode(mode)
    }

    func addMarker(_ text: String) {
        guard recorder.currentDirectory != nil else {
            appendLog("Start a scan or logging session before adding markers.")
            return
        }
        recorder.marker(text)
        appendLog("MARKER: \(text)")
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === outputStream {
                outputReady = true
                appendLog("Output stream opened")
            } else if aStream === inputStream {
                inputReady = true
                appendLog("Input stream opened")
            }
            completeConnectionIfReady()

        case .hasBytesAvailable:
            readAvailableBytes()

        case .hasSpaceAvailable:
            flushWrites()

        case .errorOccurred:
            let message = aStream.streamError?.localizedDescription ?? "unknown stream error"
            appendLog("Stream error: \(message)")
            failConnection("Connection error: \(message)")

        case .endEncountered:
            appendLog("Stream ended")
            failConnection("Accessory disconnected")

        default:
            break
        }
    }

    private func completeConnectionIfReady() {
        guard inputReady, outputReady, !isConnected else { return }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        isConnecting = false
        isConnected = true
        status = "Connected to \(connectedName ?? "OBDLink")"
        enqueue([q("ATI", 5, "Initial adapter check")])
    }

    private func failConnection(_ message: String) {
        close(preserveStatus: true)
        status = message
    }

    private func enqueue(_ commands: [QueuedCommand]) {
        guard !commands.isEmpty else {
            queueDidDrain()
            return
        }
        commandQueue.append(contentsOf: commands)
        isBusy = true
        startNextCommandIfPossible()
    }

    private func startNextCommandIfPossible() {
        guard activeCommand == nil, !discardingUntilPrompt else { return }
        guard isConnected else {
            isBusy = false
            return
        }
        guard !commandQueue.isEmpty else {
            isBusy = false
            queueDidDrain()
            return
        }
        guard outputStream != nil else { return }

        let command = commandQueue.removeFirst()
        activeCommand = command
        activeBuffer = ""
        appendLog("→ \(command.text)")
        recorder.raw("[\(timeStamp())] → \(command.text) | \(command.purpose)\n")

        guard let data = "\(command.text)\r".data(using: .ascii) else {
            finishActiveCommand(response: "", timedOut: true)
            return
        }
        pendingWrites.append(data)
        flushWrites()

        let work = DispatchWorkItem { [weak self, commandID = command.id] in
            guard let self, self.activeCommand?.id == commandID else { return }
            self.appendLog("TIMEOUT: \(command.text)")
            if command.text.hasPrefix("STM") {
                self.pendingWrites.append(Data([0x0D]))
                self.flushWrites()
            }
            self.finishActiveCommand(response: self.activeBuffer, timedOut: true)
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + command.timeout, execute: work)
    }

    private func readAvailableBytes() {
        guard let inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)

        while inputStream.hasBytesAvailable {
            let count = inputStream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                if count < 0 {
                    appendLog("Read failed: \(inputStream.streamError?.localizedDescription ?? "unknown")")
                }
                return
            }

            let data = Data(buffer.prefix(count))
            guard let text = String(data: data, encoding: .ascii) else {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                appendLog("← HEX \(hex)")
                recorder.raw("← HEX \(hex)\n")
                continue
            }

            let display = text
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n\n", with: "\n")
            appendRaw(display)
            recorder.raw(display)

            if discardingUntilPrompt {
                if text.contains(">") { finishPromptRecovery() }
                continue
            }

            guard activeCommand != nil else { continue }
            activeBuffer.append(text)
            while activeBuffer.hasPrefix(">") || activeBuffer.hasPrefix("\r>") || activeBuffer.hasPrefix("\n>") {
                activeBuffer.removeFirst()
                if activeBuffer.hasPrefix(">") { activeBuffer.removeFirst() }
            }

            if let prompt = activeBuffer.firstIndex(of: ">") {
                let response = String(activeBuffer[..<prompt])
                finishActiveCommand(response: response, timedOut: false)
            }
        }
    }

    private func finishActiveCommand(response: String, timedOut: Bool) {
        guard let command = activeCommand else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        activeCommand = nil
        activeBuffer = ""

        recorder.command(command.text, response: response, timedOut: timedOut)
        if timedOut { professional.markTimeout() }
        process(command: command.text, response: response)

        if workflow != .none {
            planCompleted += 1
            if planTotal > 0 {
                progress = min(1, Double(planCompleted) / Double(planTotal))
                progressText = "\(planCompleted) / \(planTotal) · \(command.purpose)"
            }
        }

        if timedOut {
            beginPromptRecovery(sendBreak: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startNextCommandIfPossible()
            }
        }
    }

    private func beginPromptRecovery(sendBreak: Bool) {
        discardingUntilPrompt = true
        promptRecoveryWorkItem?.cancel()
        if sendBreak, let data = "\r".data(using: .ascii) {
            pendingWrites.insert(data, at: 0)
            flushWrites()
        }
        let work = DispatchWorkItem { [weak self] in
            self?.finishPromptRecovery()
        }
        promptRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func finishPromptRecovery() {
        guard discardingUntilPrompt else { return }
        promptRecoveryWorkItem?.cancel()
        promptRecoveryWorkItem = nil
        discardingUntilPrompt = false
        activeBuffer = ""
        DispatchQueue.main.async { [weak self] in
            self?.startNextCommandIfPossible()
        }
    }

    private func process(command: String, response: String) {
        let upper = command.uppercased()

        if upper.hasPrefix("01"), upper.count >= 4,
           let pid = UInt8(upper.dropFirst(2).prefix(2), radix: 16) {
            if pid % 0x20 == 0 {
                supportedPIDs.formUnion(OBDDecoder.supportedIDs(responseService: 0x41, base: pid, response: response))
                supportedPIDCount = supportedPIDs.count
            } else {
                if let decoded = OBDDecoder.decodeMode01(pid: pid, response: response) {
                    latestValues[decoded.name] = "\(decoded.value)\(decoded.unit.isEmpty ? "" : " \(decoded.unit)")"
                    recorder.sample(command: command, decoded: decoded)
                }
                for sample in professional.recordMode01(pid: pid, response: response) {
                    let value = sample.textValue ?? sample.numericValue.map { String(format: "%.4g", $0) } ?? "raw"
                    let unit = sample.unit.map { " \($0)" } ?? ""
                    latestValues[sample.signal.description] = value + unit
                }
            }
        }

        if upper.hasPrefix("02"), upper.count >= 6 {
            professional.recordFreezeFrame(command: upper, response: response)
        }

        if upper.hasPrefix("06"), upper.count >= 4,
           let mid = UInt8(upper.dropFirst(2).prefix(2), radix: 16) {
            if mid % 0x20 == 0 {
                supportedMIDs.formUnion(OBDDecoder.supportedIDs(responseService: 0x46, base: mid, response: response))
            } else {
                professional.recordMode06(command: upper, response: response)
            }
        }

        if upper == "03" {
            addDTCs(OBDDecoder.decodeDTCs(service: 0x43, response: response), label: "stored")
        } else if upper == "07" {
            addDTCs(OBDDecoder.decodeDTCs(service: 0x47, response: response), label: "pending")
        } else if upper == "0A" {
            addDTCs(OBDDecoder.decodeDTCs(service: 0x4A, response: response), label: "permanent")
        }

        if upper == "0902", let decodedVIN = OBDDecoder.decodeVIN(response: response) {
            vin = decodedVIN
            latestValues["VIN"] = decodedVIN
        } else if upper == "0904", let value = OBDDecoder.asciiPayload(service: 0x49, pid: 0x04, response: response) {
            latestValues["Calibration ID"] = value
            adapterDetails["calibrationID"] = value
        } else if upper == "0906" {
            latestValues["CVN raw"] = compact(response)
            adapterDetails["cvn"] = compact(response)
        } else if upper == "090A", let value = OBDDecoder.asciiPayload(service: 0x49, pid: 0x0A, response: response) {
            latestValues["ECU name"] = value
        }

        switch upper {
        case "ATI": adapterDetails["ATI"] = compact(response)
        case "STI": adapterDetails["firmware"] = compact(response)
        case "STDI": adapterDetails["hardware"] = compact(response)
        case "STIX": adapterDetails["extendedFirmware"] = compact(response)
        case "STDIX": adapterDetails["extendedDevice"] = compact(response)
        case "STMFR": adapterDetails["manufacturer"] = compact(response)
        case "ATRV":
            latestValues["Adapter voltage"] = compact(response)
        case "ATDP","STPRS":
            protocolDescription = compact(response)
            latestValues["Protocol"] = protocolDescription
        case "ATDPN","STPR":
            adapterDetails["protocolNumber"] = compact(response)
        case "STPBRR":
            adapterDetails["protocolBaud"] = compact(response)
            latestValues["Protocol baud"] = compact(response)
        default:
            break
        }

        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)
        if !professional.selectedPackIDs.isEmpty {
            latestValues["Diagnostic data packs"] = professional.selectedPackIDs.joined(separator: ", ")
        }
    }

    private func queueDidDrain() {
        switch workflow {
        case .deepDiscovery:
            workflow = .deepSnapshot
            var commands: [QueuedCommand] = []
            // Query every PID advertised by any responding ECU. Unknown formulas remain raw.
            let discovered = supportedPIDs
                .filter { $0 % 0x20 != 0 }
                .sorted()
            let selectedPIDs = discovered.isEmpty
                ? ScanPreset.p2188Idle.preferredPIDs
                : discovered

            for pid in selectedPIDs {
                commands.append(q(String(format: "01%02X", pid), 10, PIDCatalog.definitions[pid]?.name ?? "SAE PID"))
            }

            let freezePIDs: [UInt8] = [0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x14,0x15]
            for pid in freezePIDs where supportedPIDs.isEmpty || supportedPIDs.contains(pid) {
                commands.append(q(String(format: "02%02X00", pid), 10, "Freeze-frame \(PIDCatalog.definitions[pid]?.name ?? "PID")"))
            }

            let monitorIDs = supportedMIDs.filter { $0 % 0x20 != 0 }.sorted().prefix(32)
            for mid in monitorIDs {
                commands.append(q(String(format: "06%02X", mid), 10, "Mode 06 monitor result"))
            }

            commands.append(q("STMA 200", 25, "Passive bus capture — 200 messages"))
            planTotal += commands.count
            progressText = "Reading all supported values…"
            enqueue(commands)

        case .deepSnapshot:
            finishWorkflow(summaryLabel: "Deep scan completed")

        case .continuous:
            if continuousPreset != nil {
                scheduleContinuousCycle(after: 0.05)
            }

        case .none:
            break
        }
    }

    private func scheduleContinuousCycle(after delay: TimeInterval) {
        nextCycleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enqueueContinuousCycle() }
        nextCycleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    private func enqueueContinuousCycle() {
        guard workflow == .continuous, let preset = continuousPreset else { return }
        let now = Date()
        let planned = professional.plannedCommands(for: preset)
        var commands: [QueuedCommand] = []

        if !planned.isEmpty {
            for item in planned {
                let due = continuousNextDue[item.text] ?? .distantPast
                guard due <= now else { continue }
                commands.append(q(item.text, item.timeout, item.purpose))
                continuousNextDue[item.text] = now.addingTimeInterval(1 / max(0.05, item.targetFrequencyHz))
            }
        } else {
            let requested: [UInt8]
            if preset == .allSupported, !supportedPIDs.isEmpty {
                requested = supportedPIDs.filter { $0 % 0x20 != 0 }.sorted()
            } else {
                requested = preset.preferredPIDs
            }
            for pid in requested where supportedPIDs.isEmpty || supportedPIDs.contains(pid) {
                let command = String(format: "01%02X", pid)
                let due = continuousNextDue[command] ?? .distantPast
                guard due <= now else { continue }
                commands.append(q(command, 8, PIDCatalog.definitions[pid]?.name ?? "Live PID"))
                continuousNextDue[command] = now.addingTimeInterval(1)
            }
        }

        let healthDue = lastContinuousHealthAt.map { now.timeIntervalSince($0) >= 30 } ?? true
        if healthDue {
            commands.insert(q("ATRV", 3, "Adapter voltage"), at: 0)
            commands.append(q("0101", 8, "Readiness/MIL snapshot"))
            commands.append(q("07", 10, "Pending DTC snapshot"))
            lastContinuousHealthAt = now
        }

        if commands.isEmpty {
            let delay = continuousNextDue.values
                .map { max(0.05, $0.timeIntervalSinceNow) }
                .min() ?? 0.25
            scheduleContinuousCycle(after: min(0.5, delay))
            return
        }

        continuousCycleCount += 1
        planTotal = commands.count
        planCompleted = 0
        progress = 0
        progressText = "Cycle \(continuousCycleCount) · frequency-aware"
        enqueue(commands)
    }

    private func stopWorkflow(save: Bool) {
        let hadActiveCommand = activeCommand != nil
        let activeWasMonitor = activeCommand?.text.hasPrefix("STM") == true
        nextCycleWorkItem?.cancel()
        timeoutWorkItem?.cancel()
        nextCycleWorkItem = nil
        timeoutWorkItem = nil
        commandQueue.removeAll()
        pendingWrites.removeAll()
        activeCommand = nil
        activeBuffer = ""
        workflow = .none
        continuousPreset = nil
        continuousNextDue.removeAll()
        lastContinuousHealthAt = nil
        isBusy = false
        isLogging = false
        progress = 0
        progressText = ""
        if hadActiveCommand {
            beginPromptRecovery(sendBreak: activeWasMonitor)
        }
        if save {
            finishRecorder(summaryLabel: "Stopped by user")
        }
        activeScenario = ""
    }

    private func finishWorkflow(summaryLabel: String) {
        workflow = .none
        isBusy = false
        isLogging = false
        progress = 1
        progressText = summaryLabel
        finishRecorder(summaryLabel: summaryLabel)
        activeScenario = ""
        status = "Connected to \(connectedName ?? "OBDLink MX+")"
    }

    private func finishRecorder(summaryLabel: String) {
        guard recorder.currentDirectory != nil else { return }
        var summary = adapterDetails
        summary["result"] = summaryLabel
        summary["vehicle"] = professional.vehicleDisplayName
        summary["VIN"] = vin
        summary["protocol"] = protocolDescription
        summary["supportedPIDCount"] = String(supportedPIDs.count)
        summary["supportedPIDs"] = supportedPIDs.sorted().map { String(format: "%02X", $0) }.joined(separator: ",")
        summary["supportedMode06MIDs"] = supportedMIDs.sorted().map { String(format: "%02X", $0) }.joined(separator: ",")
        summary["DTCs"] = dtcs.joined(separator: ", ")
        for (key, value) in latestValues {
            summary["value.\(key)"] = value
        }
        _ = professional.finishSession(dtcs: dtcs, summaryLabel: summaryLabel, supportedPIDs: supportedPIDs, protocolDescription: protocolDescription, adapterDetails: adapterDetails)
        recorder.finish(summary: summary)
    }

    private func addDTCs(_ codes: [String], label: String) {
        for code in codes {
            let description = OBDDecoder.dtcDescription(code).map { " — \($0)" } ?? ""
            let value = "\(code) [\(label)]\(description)"
            if !dtcs.contains(value) {
                dtcs.append(value)
            }
        }
    }

    private func q(_ text: String, _ timeout: TimeInterval, _ purpose: String) -> QueuedCommand {
        QueuedCommand(text: text, timeout: timeout, purpose: purpose)
    }

    private func normalized(_ value: String) -> String {
        ReadOnlyCommandPolicy.normalize(value)
    }

    private func isSafeReadOnlyManualCommand(_ command: String) -> Bool {
        ReadOnlyCommandPolicy.isAllowed(command)
    }

    private func compact(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func flushWrites() {
        guard let outputStream else { return }

        while outputStream.hasSpaceAvailable, !pendingWrites.isEmpty {
            let data = pendingWrites.removeFirst()
            let bytesWritten = data.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return outputStream.write(base, maxLength: data.count)
            }

            if bytesWritten < 0 {
                appendLog("Write failed: \(outputStream.streamError?.localizedDescription ?? "unknown")")
                return
            }

            if bytesWritten < data.count {
                pendingWrites.insert(Data(data.dropFirst(bytesWritten)), at: 0)
                return
            }
        }
    }

    private func appendRaw(_ text: String) {
        guard !text.isEmpty else { return }
        log.append(text)
        if !text.hasSuffix("\n") { log.append("\n") }
        trimLogIfNeeded()
    }

    private func appendLog(_ message: String) {
        log.append("[\(timeStamp())] \(message)\n")
        trimLogIfNeeded()
    }

    private func timeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func trimLogIfNeeded() {
        let limit = 160_000
        if log.count > limit {
            log = String(log.suffix(limit))
        }
    }

    private func configureDemoState() {
        accessories = [
            AccessorySummary(
                id: 1,
                name: "OBDLink MX+",
                model: "MX+",
                manufacturer: "OBD Solutions",
                protocols: [Self.obdLinkProtocol]
            )
        ]
        connectedName = "OBDLink MX+"
        status = "Connected to OBDLink MX+"
        isConnected = true
        isConnecting = false
        protocolDescription = "ISO 15765-4 CAN (11 bit, 500 kbaud)"
        supportedPIDCount = 43
        vin = "JMZCR19F270123456"
        latestValues = [
            "Engine RPM": "760 rpm",
            "Short fuel trim B1": "-22.00 %",
            "Long fuel trim B1": "-8.00 %",
            "Coolant temperature": "91.00 °C",
            "Mass air flow": "3.10 g/s",
            "Commanded EVAP purge": "12.00 %",
            "Control module voltage": "14.10 V"
        ]
        dtcs = ["P2188 [stored] — System too rich at idle, bank 1"]
        log = "[09:00:00.000] Demo mode for automated UX testing\n41 0C 0B E0 >\n"
        professional.analysisClient.configureForUITesting()
    }

}
