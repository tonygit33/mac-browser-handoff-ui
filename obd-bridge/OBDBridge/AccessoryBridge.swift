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

    private var accessory: EAAccessory?
    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var pendingWrites: [Data] = []

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
            status = "OBDLink found — ready to connect"
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
        let command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !command.isEmpty else { return }
        guard outputStream != nil else {
            appendLog("Not connected; command ignored: \(command)")
            return
        }

        guard let data = "\(command)\r".data(using: .ascii) else { return }
        pendingWrites.append(data)
        appendLog("→ \(command)")
        flushWrites()
    }

    func runReadOnlyProbe() {
        guard isConnected else {
            appendLog("Connect before running the probe")
            return
        }

        // Read-only initialization and standard OBD-II discovery.
        let sequence: [(TimeInterval, String)] = [
            (0.0, "ATZ"),
            (1.6, "ATE0"),
            (2.0, "ATL0"),
            (2.4, "ATS0"),
            (2.8, "ATH0"),
            (3.2, "ATSP0"),
            (3.8, "ATI"),
            (4.2, "ATRV"),
            (4.8, "0100"),
            (5.5, "0120"),
            (6.2, "0902")
        ]

        for (delay, command) in sequence {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(command)
            }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === outputStream {
                isConnected = true
                status = "Connected to \(connectedName ?? "OBDLink")"
                appendLog("Output stream opened")
                send("ATI")
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
                let cleaned = text
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n\n", with: "\n")
                appendRaw(cleaned)
            } else {
                appendLog("← HEX \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
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
                pendingWrites.insert(data.dropFirst(bytesWritten), at: 0)
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
