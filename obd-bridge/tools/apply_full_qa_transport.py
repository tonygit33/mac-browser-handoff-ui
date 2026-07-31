#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "AccessoryBridge.swift"
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:100]!r}")
    text = text.replace(old, new, 1)


replace_once(
    '    @Published private(set) var isLogging = false\n',
    '    @Published private(set) var isLogging = false\n'
    '    @Published private(set) var isConnecting = false\n'
)

replace_once(
    '    private var currentFuelMode: FuelMode = .unknown\n    private var adapterDetails: [String:String] = [:]\n',
    '    private var currentFuelMode: FuelMode = .unknown\n'
    '    private var adapterDetails: [String:String] = [:]\n'
    '    private var inputReady = false\n'
    '    private var outputReady = false\n'
    '    private var connectionTimeoutWorkItem: DispatchWorkItem?\n'
    '    private var promptRecoveryWorkItem: DispatchWorkItem?\n'
    '    private var discardingUntilPrompt = false\n'
    '    private var continuousNextDue: [String: Date] = [:]\n'
    '    private var lastContinuousHealthAt: Date?\n'
    '    private let demoMode = ProcessInfo.processInfo.arguments.contains("--ui-testing-demo")\n'
)

replace_once(
'''    override init() {
        super.init()
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
''',
'''    override init() {
        super.init()
        if demoMode {
            configureDemoState()
            return
        }
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
'''
)

replace_once(
'''    deinit {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        close()
    }
''',
'''    deinit {
        NotificationCenter.default.removeObserver(self)
        if !demoMode {
            EAAccessoryManager.shared().unregisterForLocalNotifications()
        }
        close()
    }
'''
)

replace_once(
'''    func refreshAccessories() {
        let found = EAAccessoryManager.shared().connectedAccessories
''',
'''    func refreshAccessories() {
        if demoMode { return }
        let found = EAAccessoryManager.shared().connectedAccessories
'''
)

start = text.index('    func connect() {')
end = text.index('    func clearLog() {', start)
text = text[:start] + '''    func connect() {
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

''' + text[end:]

replace_once(
'''        continuousPreset = preset
        continuousCycleCount = 0
''',
'''        continuousPreset = preset
        continuousCycleCount = 0
        continuousNextDue.removeAll()
        lastContinuousHealthAt = nil
'''
)

start = text.index('    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {')
end = text.index('    private func enqueue(_ commands: [QueuedCommand]) {', start)
text = text[:start] + '''    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
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

''' + text[end:]

replace_once(
'''    private func startNextCommandIfPossible() {
        guard activeCommand == nil else { return }
''',
'''    private func startNextCommandIfPossible() {
        guard activeCommand == nil, !discardingUntilPrompt else { return }
        guard isConnected else {
            isBusy = false
            return
        }
'''
)

replace_once(
'''            guard activeCommand != nil else { continue }
            activeBuffer.append(text)
''',
'''            if discardingUntilPrompt {
                if text.contains(">") { finishPromptRecovery() }
                continue
            }

            guard activeCommand != nil else { continue }
            activeBuffer.append(text)
'''
)

start = text.index('    private func finishActiveCommand(response: String, timedOut: Bool) {')
end = text.index('    private func process(command: String, response: String) {', start)
text = text[:start] + '''    private func finishActiveCommand(response: String, timedOut: Bool) {
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
        if sendBreak, let data = "\\r".data(using: .ascii) {
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

''' + text[end:]

replace_once(
'''        case .continuous:
            if continuousPreset != nil {
                nextCycleWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.enqueueContinuousCycle() }
                nextCycleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
''',
'''        case .continuous:
            if continuousPreset != nil {
                scheduleContinuousCycle(after: 0.05)
            }
'''
)

start = text.index('    private func enqueueContinuousCycle() {')
end = text.index('    private func stopWorkflow(save: Bool) {', start)
text = text[:start] + '''    private func scheduleContinuousCycle(after delay: TimeInterval) {
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

''' + text[end:]

start = text.index('    private func stopWorkflow(save: Bool) {')
end = text.index('    private func finishWorkflow(summaryLabel: String) {', start)
text = text[:start] + '''    private func stopWorkflow(save: Bool) {
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

''' + text[end:]

replace_once(
'''    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func isSafeReadOnlyManualCommand(_ command: String) -> Bool {
        let compact = normalized(command)
        if compact.range(of: "^[0-9A-F]+$", options: .regularExpression) != nil,
           compact.count >= 2 {
            let mode = String(compact.prefix(2))
            return ["01","02","03","06","07","09","0A"].contains(mode)
        }

        let safeExact = [
            "ATI","ATRV","ATDP","ATDPN","ATH0","ATH1","ATS0","ATS1","ATL0","ATL1",
            "ATE0","ATE1","ATSP0","ATZ","STI","STDI","STIX","STDIX","STMFR",
            "STPR","STPRS","STPBRR","STVR"
        ]
        if safeExact.contains(compact) { return true }
        return compact.range(of: "^STM(A)?[0-9]+$", options: .regularExpression) != nil
    }
''',
'''    private func normalized(_ value: String) -> String {
        ReadOnlyCommandPolicy.normalize(value)
    }

    private func isSafeReadOnlyManualCommand(_ command: String) -> Bool {
        ReadOnlyCommandPolicy.isAllowed(command)
    }
'''
)

insert_at = text.rfind('\n}')
demo = '''

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
        log = "[09:00:00.000] Demo mode for automated UX testing\\n41 0C 0B E0 >\\n"
        professional.analysisClient.configureForUITesting()
    }
'''
text = text[:insert_at] + demo + text[insert_at:]

path.write_text(text)
print(f"patched {path}")
