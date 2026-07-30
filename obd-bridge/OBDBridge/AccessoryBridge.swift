import Foundation
import ExternalAccessory

struct AccessorySummary: Identifiable, Hashable {
    let id: Int
    let name: String
    let model: String
    let manufacturer: String
    let protocols: [String]
}

final class AccessoryBridge: NSObject, ObservableObject, StreamDelegate {
    static let obdLinkProtocol = "com.obdlink"

    @Published private(set) var accessories: [AccessorySummary] = []
    @Published private(set) var status = "Looking for paired OBDLink MX+…"
    @Published private(set) var connectedName: String?
    @Published private(set) var log = ""
    @Published private(set) var isConnected = false

    // Parsed values are retained for the next dashboard iteration.
    @Published private(set) var adapterVersion: String?
    @Published private(set) var vehicleVoltage: Double?
    @Published private(set) var vin: String?
    @Published private(set) var engineRPM: Double?

    private var accessory: EAAccessory?
    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var pendingWrites: [Data] = []

    // ELM327/OBDLink is prompt-driven. Never send the next command until ">" arrives.
    private var commandQueue: [String] = []
    private var activeCommand: String?
    private var receiveBuffer = ""
    private var commandTimeout: DispatchWorkItem?
    private var probeRunning = false

    override init() {
        super.init()
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
        EAAccessoryManager.shared().unregisterForLocalNotifications()
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
        } else if found.contains(where: { $0.protocolStrings.contains(Self.obdLinkProtocol) }) {
            status = isConnected ? "Connected to OBDLink MX+" : "OBDLink found — ready to connect"
        } else {
            status = "Accessory found, but com.obdlink is not advertised"
        }
    }

    func connect() {
        close()
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
    }

    func close() {
        commandTimeout?.cancel()
        commandTimeout = nil
        commandQueue.removeAll()
        activeCommand = nil
        receiveBuffer = ""
        probeRunning = false

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
        connectedName = nil
        isConnected = false
    }

    func clearLog() {
        log = ""
    }

    func send(_ rawCommand: String) {
        let command = normalizedCommand(rawCommand)
        guard !command.isEmpty else { return }
        guard isConnected else {
            appendLog("Not connected; command ignored: \(command)")
            return
        }

        commandQueue.append(command)
        pumpCommandQueue()
    }

    func runReadOnlyProbe() {
        guard isConnected else {
            appendLog("Connect before running the probe")
            return
        }
        guard activeCommand == nil, commandQueue.isEmpty, !probeRunning else {
            appendLog("A command is already running; wait for the prompt")
            return
        }

        adapterVersion = nil
        vehicleVoltage = nil
        vin = nil
        engineRPM = nil
        probeRunning = true
        status = "Running read-only probe…"

        // Read-only initialization and standard OBD-II discovery.
        commandQueue = [
            "ATZ",
            "ATE0",
            "ATL0",
            "ATS0",
            "ATH0",
            "ATSP0",
            "ATI",
            "ATRV",
            "0100",
            "0120",
            "0902",
            "010C"
        ]
        pumpCommandQueue()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === outputStream {
                isConnected = true
                status = "Connected to \(connectedName ?? "OBDLink")"
                appendLog("Output stream opened")
                commandQueue.append("ATI")
                pumpCommandQueue()
            } else {
                appendLog("Input stream opened")
            }

        case .hasBytesAvailable:
            readAvailableBytes()

        case .hasSpaceAvailable:
            flushWrites()

        case .errorOccurred:
            let message = aStream.streamError?.localizedDescription ?? "unknown stream error"
            appendLog("Stream error: \(message)")
            status = "Connection error"

        case .endEncountered:
            appendLog("Stream ended")
            status = "Disconnected"
            close()

        default:
            break
        }
    }

    private func normalizedCommand(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func pumpCommandQueue() {
        guard isConnected, activeCommand == nil, !commandQueue.isEmpty else {
            if probeRunning, activeCommand == nil, commandQueue.isEmpty {
                probeRunning = false
                status = "Probe completed"
                appendProbeSummary()
            }
            return
        }

        let command = commandQueue.removeFirst()
        guard let data = "\(command)\r".data(using: .ascii) else { return }

        activeCommand = command
        receiveBuffer = ""
        pendingWrites.append(data)
        appendLog("→ \(command)")
        scheduleTimeout(for: command)
        flushWrites()
    }

    private func scheduleTimeout(for command: String) {
        commandTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.activeCommand == command else { return }
            self.appendLog("Timeout waiting for prompt after \(command)")
            self.status = "Command timed out"
            self.commandQueue.removeAll()
            self.activeCommand = nil
            self.probeRunning = false

            // A bare carriage return safely interrupts an ELM search and restores the prompt.
            if let abort = "\r".data(using: .ascii) {
                self.pendingWrites.append(abort)
                self.flushWrites()
            }
        }
        commandTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: timeout)
    }

    private func readAvailableBytes() {
        guard let inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)

        while inputStream.hasBytesAvailable {
            let count = inputStream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                if count < 0 {
                    appendLog("Read failed: \(inputStream.streamError?.localizedDescription ?? "unknown")")
                }
                return
            }

            let data = Data(buffer.prefix(count))
            if let text = String(data: data, encoding: .ascii) {
                appendRaw(
                    text.replacingOccurrences(of: "\r", with: "\n")
                        .replacingOccurrences(of: "\n\n", with: "\n")
                )
                processIncoming(text)
            } else {
                appendLog("← HEX \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
    }

    private func processIncoming(_ text: String) {
        receiveBuffer.append(text)

        while let promptRange = receiveBuffer.range(of: ">") {
            let response = String(receiveBuffer[..<promptRange.lowerBound])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<promptRange.upperBound)
            completeActiveCommand(response: response)
        }
    }

    private func completeActiveCommand(response: String) {
        commandTimeout?.cancel()
        commandTimeout = nil

        if let command = activeCommand {
            decode(command: command, response: response)
        }
        activeCommand = nil

        // Let the adapter settle, then send exactly one next command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pumpCommandQueue()
        }
    }

    private func decode(command: String, response: String) {
        let lines = response
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != command }

        switch command {
        case "ATI":
            if let version = lines.first(where: { $0.uppercased().contains("ELM") || $0.uppercased().contains("OBDLINK") }) {
                adapterVersion = version
                appendLog("✓ Adapter: \(version)")
            }

        case "ATRV":
            for line in lines {
                let cleaned = line.uppercased().replacingOccurrences(of: "V", with: "")
                if let value = Double(cleaned) {
                    vehicleVoltage = value
                    appendLog(String(format: "✓ Supply voltage: %.1f V", value))
                    break
                }
            }

        case "010C":
            if let payload = hexPayload(in: response, prefix: "410C", byteCount: 2), payload.count == 4,
               let raw = Int(payload, radix: 16) {
                let rpm = Double(raw) / 4.0
                engineRPM = rpm
                appendLog(String(format: "✓ Engine speed: %.0f rpm", rpm))
            }

        case "0902":
            if let decodedVIN = decodeVIN(response), decodedVIN.count == 17 {
                vin = decodedVIN
                appendLog("✓ VIN: \(decodedVIN)")
            }

        case "0100":
            if let bitmap = hexPayload(in: response, prefix: "4100", byteCount: 4) {
                appendLog("✓ Supported PIDs 01–20 bitmap: \(bitmap)")
            }

        case "0120":
            if let bitmap = hexPayload(in: response, prefix: "4120", byteCount: 4) {
                appendLog("✓ Supported PIDs 21–40 bitmap: \(bitmap)")
            }

        default:
            break
        }
    }

    private func hexPayload(in response: String, prefix: String, byteCount: Int) -> String? {
        let compact = response.uppercased().filter { $0.isHexDigit }
        guard let range = compact.range(of: prefix) else { return nil }
        let start = range.upperBound
        let end = compact.index(start, offsetBy: byteCount * 2, limitedBy: compact.endIndex) ?? compact.endIndex
        let payload = String(compact[start..<end])
        return payload.count == byteCount * 2 ? payload : nil
    }

    private func decodeVIN(_ response: String) -> String? {
        var framedHex = ""
        let lines = response
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let colon = line.firstIndex(of: ":") {
                let afterColon = line[line.index(after: colon)...]
                framedHex += afterColon.filter { $0.isHexDigit }
            } else if line.uppercased().contains("490201") {
                framedHex += line.filter { $0.isHexDigit }
            }
        }

        let upper = framedHex.uppercased()
        guard let marker = upper.range(of: "490201") else { return nil }
        let vinHex = String(upper[marker.upperBound...])
        var characters: [Character] = []
        var index = vinHex.startIndex

        while vinHex.distance(from: index, to: vinHex.endIndex) >= 2, characters.count < 17 {
            let next = vinHex.index(index, offsetBy: 2)
            let byteText = String(vinHex[index..<next])
            guard let byte = UInt8(byteText, radix: 16), byte >= 0x20, byte <= 0x7E else {
                index = next
                continue
            }
            characters.append(Character(UnicodeScalar(byte)))
            index = next
        }

        let result = String(characters)
        return result.count == 17 ? result : nil
    }

    private func appendProbeSummary() {
        appendLog("Probe finished without write/service commands")
        if let adapterVersion { appendLog("Summary adapter: \(adapterVersion)") }
        if let vehicleVoltage { appendLog(String(format: "Summary voltage: %.1f V", vehicleVoltage)) }
        if let vin { appendLog("Summary VIN: \(vin)") }
        if let engineRPM { appendLog(String(format: "Summary RPM: %.0f", engineRPM)) }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        log.append("[\(formatter.string(from: Date()))] \(message)\n")
        trimLogIfNeeded()
    }

    private func trimLogIfNeeded() {
        let limit = 120_000
        if log.count > limit {
            log = String(log.suffix(limit))
        }
    }
}
