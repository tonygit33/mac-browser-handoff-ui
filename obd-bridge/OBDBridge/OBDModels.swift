import Foundation

enum FuelMode: String, CaseIterable, Identifiable, Codable {
    case unknown = "Unknown"
    case gasoline = "Gasoline"
    case lpg = "LPG"

    var id: String { rawValue }
}

enum ScanPreset: String, CaseIterable, Identifiable {
    case p2188Idle = "P2188 / fuel trims"
    case coldStart = "Cold start"
    case warmIdle = "Warm idle"
    case rpm2500 = "2500 RPM"
    case road = "Road test"
    case allSupported = "All supported PIDs"

    var id: String { rawValue }

    var instructions: String {
        switch self {
        case .p2188Idle:
            return "Warm engine, accessories off. Log at idle, then briefly at 2500 RPM."
        case .coldStart:
            return "Start logging with ignition on and engine cold, then start the engine."
        case .warmIdle:
            return "Warm engine fully and leave it idling for 3–5 minutes."
        case .rpm2500:
            return "Stationary, transmission in P/N, hold near 2500 RPM for 30–60 seconds."
        case .road:
            return "Start before driving. Do not touch the phone while the vehicle is moving."
        case .allSupported:
            return "Cycles through every supported standard PID discovered by the deep scan."
        }
    }

    var preferredPIDs: [UInt8] {
        switch self {
        case .p2188Idle:
            return [0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x13,0x14,0x15,0x1C,0x1F,0x2F,0x33,0x42,0x43,0x44,0x45,0x46,0x49,0x4A,0x4C,0x51,0x5E]
        case .coldStart:
            return [0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0E,0x0F,0x10,0x11,0x14,0x15,0x1F,0x42,0x43,0x44,0x46]
        case .warmIdle:
            return [0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0E,0x0F,0x10,0x11,0x14,0x15,0x2F,0x33,0x42,0x43,0x44,0x46,0x5E]
        case .rpm2500:
            return [0x04,0x05,0x06,0x07,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x14,0x15,0x42,0x43,0x44,0x4C,0x5E]
        case .road:
            return [0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x14,0x15,0x1F,0x21,0x2F,0x31,0x33,0x42,0x43,0x44,0x46,0x49,0x4A,0x4C,0x5E]
        case .allSupported:
            return Array(PIDCatalog.definitions.keys).sorted()
        }
    }
}

struct PIDDefinition {
    let pid: UInt8
    let name: String
    let unit: String
}

enum PIDCatalog {
    static let definitions: [UInt8: PIDDefinition] = {
        let rows: [(UInt8,String,String)] = [
            (0x01,"Monitor status",""),(0x02,"Freeze-frame DTC",""),(0x03,"Fuel system status",""),
            (0x04,"Calculated load","%"),(0x05,"Coolant temperature","°C"),(0x06,"Short fuel trim B1","%"),
            (0x07,"Long fuel trim B1","%"),(0x08,"Short fuel trim B2","%"),(0x09,"Long fuel trim B2","%"),
            (0x0A,"Fuel pressure","kPa"),(0x0B,"Intake manifold pressure","kPa"),(0x0C,"Engine RPM","rpm"),
            (0x0D,"Vehicle speed","km/h"),(0x0E,"Timing advance","°"),(0x0F,"Intake air temperature","°C"),
            (0x10,"Mass air flow","g/s"),(0x11,"Throttle position","%"),(0x12,"Secondary air status",""),
            (0x13,"Oxygen sensors present",""),(0x14,"O2 B1S1 voltage","V"),(0x15,"O2 B1S2 voltage","V"),
            (0x16,"O2 B1S3 voltage","V"),(0x17,"O2 B1S4 voltage","V"),(0x18,"O2 B2S1 voltage","V"),
            (0x19,"O2 B2S2 voltage","V"),(0x1A,"O2 B2S3 voltage","V"),(0x1B,"O2 B2S4 voltage","V"),
            (0x1C,"OBD standard",""),(0x1F,"Engine run time","s"),(0x21,"Distance with MIL on","km"),
            (0x22,"Fuel rail pressure","kPa"),(0x23,"Fuel rail gauge pressure","kPa"),(0x24,"Wideband O2 B1S1","λ"),
            (0x25,"Wideband O2 B1S2","λ"),(0x2C,"Commanded EGR","%"),(0x2D,"EGR error","%"),
            (0x2E,"Commanded EVAP purge","%"),(0x2F,"Fuel level","%"),(0x30,"Warm-ups since clear","count"),
            (0x31,"Distance since clear","km"),(0x32,"EVAP vapor pressure","Pa"),(0x33,"Barometric pressure","kPa"),
            (0x3C,"Catalyst temp B1S1","°C"),(0x3D,"Catalyst temp B2S1","°C"),(0x3E,"Catalyst temp B1S2","°C"),
            (0x3F,"Catalyst temp B2S2","°C"),(0x42,"Control module voltage","V"),(0x43,"Absolute load","%"),
            (0x44,"Commanded equivalence ratio","λ"),(0x45,"Relative throttle position","%"),(0x46,"Ambient air temperature","°C"),
            (0x47,"Absolute throttle B","%"),(0x48,"Absolute throttle C","%"),(0x49,"Accelerator pedal D","%"),
            (0x4A,"Accelerator pedal E","%"),(0x4B,"Accelerator pedal F","%"),(0x4C,"Commanded throttle actuator","%"),
            (0x4D,"Time with MIL on","min"),(0x4E,"Time since DTC clear","min"),(0x51,"Fuel type",""),
            (0x52,"Ethanol fuel percentage","%"),(0x53,"Absolute EVAP vapor pressure","kPa"),
            (0x59,"Fuel rail absolute pressure","kPa"),(0x5A,"Relative accelerator pedal","%"),
            (0x5B,"Hybrid battery life","%"),(0x5C,"Engine oil temperature","°C"),(0x5E,"Engine fuel rate","L/h"),
            (0x61,"Driver demand torque","%"),(0x62,"Actual engine torque","%"),(0x63,"Engine reference torque","Nm")
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, PIDDefinition(pid: $0.0, name: $0.1, unit: $0.2)) })
    }()

    static let mazda2007ExpectedEnhancedNames = [
        "ACCS","ALTF","ARPMDES","EVAPCP","FAN_DUTY","FP","FUELPW1","GENVDSD",
        "HTR11","HTR12","IMRC","IMTV","INJ_1","INJ_2","INJ_3","INJ_4","SEGRP","VT DUTY1"
    ]
}

struct DecodedPID {
    let pid: UInt8
    let name: String
    let value: String
    let unit: String
    let numericValue: Double?
    let raw: String
}

enum OBDDecoder {
    static func byteSequences(from response: String) -> [[UInt8]] {
        response.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.uppercased().split { !$0.isHexDigit }
            var bytes: [UInt8] = []
            for tokenSub in tokens {
                var token = String(tokenSub)
                if token.count == 3 || token.count == 8 { continue }
                if token.count > 5, token.count % 2 == 1 {
                    token = String(token.dropFirst(3))
                } else if token.count > 12, token.count % 2 == 0, token.hasPrefix("18") || token.hasPrefix("19") {
                    token = String(token.dropFirst(8))
                }
                if token.count == 2, let byte = UInt8(token, radix: 16) {
                    bytes.append(byte)
                } else if token.count >= 4, token.count % 2 == 0 {
                    var index = token.startIndex
                    while index < token.endIndex {
                        let next = token.index(index, offsetBy: 2)
                        if let byte = UInt8(token[index..<next], radix: 16) { bytes.append(byte) }
                        index = next
                    }
                }
            }
            return bytes.isEmpty ? nil : bytes
        }
    }

    static func payloads(service: UInt8, pid: UInt8, response: String) -> [[UInt8]] {
        byteSequences(from: response).compactMap { bytes in
            guard let index = bytes.firstIndex(of: service), index + 1 < bytes.count, bytes[index + 1] == pid else { return nil }
            return Array(bytes.dropFirst(index + 2))
        }
    }

    static func supportedIDs(responseService: UInt8, base: UInt8, response: String) -> Set<UInt8> {
        var result = Set<UInt8>()
        for data in payloads(service: responseService, pid: base, response: response) where data.count >= 4 {
            for (byteIndex, byte) in data.prefix(4).enumerated() {
                for bit in 0..<8 where (byte & (1 << (7 - bit))) != 0 {
                    let value = Int(base) + byteIndex * 8 + bit + 1
                    if value <= 0xFF { result.insert(UInt8(value)) }
                }
            }
        }
        return result
    }

    static func decodeMode01(pid: UInt8, response: String) -> DecodedPID? {
        guard let data = payloads(service: 0x41, pid: pid, response: response).first else { return nil }
        let definition = PIDCatalog.definitions[pid]
            ?? PIDDefinition(pid: pid, name: String(format: "SAE PID 0x%02X", pid), unit: "raw")
        let a = data.count > 0 ? Double(data[0]) : 0
        let b = data.count > 1 ? Double(data[1]) : 0
        let word = a * 256 + b
        var numeric: Double?
        var text: String?
        switch pid {
        case 0x03: text = data.map { fuelStatus($0) }.joined(separator: " / ")
        case 0x04,0x11,0x2C,0x2F,0x45,0x47,0x48,0x49,0x4A,0x4B,0x4C,0x52,0x5A,0x5B: numeric = a * 100 / 255
        case 0x05,0x0F,0x46,0x5C: numeric = a - 40
        case 0x06,0x07,0x08,0x09,0x2D: numeric = (a - 128) * 100 / 128
        case 0x0A: numeric = a * 3
        case 0x0B,0x33: numeric = a
        case 0x0C: numeric = word / 4
        case 0x0D,0x30: numeric = a
        case 0x0E: numeric = a / 2 - 64
        case 0x10: numeric = word / 100
        case 0x14...0x1B: numeric = a / 200
        case 0x1C: text = String(format: "0x%02X", Int(a))
        case 0x1F,0x21,0x31,0x4D,0x4E: numeric = word
        case 0x22: numeric = word * 0.079
        case 0x23: numeric = word * 10
        case 0x24...0x2B,0x44: numeric = word * 2 / 65535
        case 0x2E: numeric = a * 100 / 255
        case 0x32: numeric = (word / 4) - 8192
        case 0x3C...0x3F: numeric = word / 10 - 40
        case 0x42: numeric = word / 1000
        case 0x43: numeric = word * 100 / 255
        case 0x51: text = fuelType(UInt8(a))
        case 0x53: numeric = word / 200
        case 0x59: numeric = word * 10
        case 0x5E: numeric = word / 20
        case 0x61,0x62: numeric = a - 125
        case 0x63: numeric = word
        default: break
        }
        if let numeric { text = format(numeric) }
        guard let value = text else {
            let rawBytes = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            return DecodedPID(pid: pid, name: definition.name, value: rawBytes, unit: "raw", numericValue: nil, raw: response)
        }
        return DecodedPID(pid: pid, name: definition.name, value: value, unit: definition.unit, numericValue: numeric, raw: response)
    }

    static func decodeDTCs(service: UInt8, response: String) -> [String] {
        var codes: [String] = []
        for bytes in byteSequences(from: response) {
            guard let index = bytes.firstIndex(of: service) else { continue }
            let data = Array(bytes.dropFirst(index + 1))
            var i = 0
            while i + 1 < data.count {
                let first = data[i], second = data[i + 1]
                if first == 0 && second == 0 { i += 2; continue }
                let family = ["P","C","B","U"][Int((first & 0xC0) >> 6)]
                let code = "\(family)\(Int((first & 0x30) >> 4))\(String(format: "%X%X%X", Int(first & 0x0F), Int((second & 0xF0) >> 4), Int(second & 0x0F)))"
                codes.append(code); i += 2
            }
        }
        return Array(Set(codes)).sorted()
    }

    static func decodeVIN(response: String) -> String? {
        var collecting = false
        var ascii: [UInt8] = []
        for rawLine in response.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            for bytes in byteSequences(from: line) {
                if let idx = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 0x49 && bytes[$0 + 1] == 0x02 }) {
                    collecting = true
                    var payload = Array(bytes.dropFirst(idx + 2))
                    if let first = payload.first, first <= 0x10 { payload.removeFirst() }
                    ascii.append(contentsOf: payload)
                } else if collecting, line.trimmingCharacters(in: .whitespaces).first?.isNumber == true {
                    var payload = bytes
                    if let first = payload.first, first <= 0x10 { payload.removeFirst() }
                    ascii.append(contentsOf: payload)
                }
            }
        }
        let value = String(bytes: ascii.filter { $0 >= 0x20 && $0 <= 0x7E }, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.count ?? 0 >= 11 ? value : nil
    }

    static func asciiPayload(service: UInt8, pid: UInt8, response: String) -> String? {
        var bytes: [UInt8] = []
        for payload in payloads(service: service, pid: pid, response: response) {
            var part = payload
            if let first = part.first, first <= 0x10 { part.removeFirst() }
            bytes.append(contentsOf: part)
        }
        let text = String(bytes: bytes.filter { $0 >= 0x20 && $0 <= 0x7E }, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func dtcDescription(_ code: String) -> String? {
        ["P0171":"System too lean, bank 1","P0172":"System too rich, bank 1","P0300":"Random/multiple cylinder misfire",
         "P0301":"Cylinder 1 misfire","P0302":"Cylinder 2 misfire","P0303":"Cylinder 3 misfire","P0304":"Cylinder 4 misfire",
         "P0441":"EVAP purge flow incorrect","P0455":"EVAP system large leak","P0456":"EVAP system very small leak",
         "P2187":"System too lean at idle, bank 1","P2188":"System too rich at idle, bank 1"][code]
    }

    private static func fuelStatus(_ value: UInt8) -> String {
        switch value { case 1: return "Open loop"; case 2: return "Closed loop"; case 4: return "Open loop—driving"; case 8: return "Open loop—fault"; case 16: return "Closed loop—fault"; default: return String(format: "0x%02X", value) }
    }
    private static func fuelType(_ value: UInt8) -> String {
        [0:"Not available",1:"Gasoline",2:"Methanol",3:"Ethanol",4:"Diesel",5:"LPG",6:"CNG",7:"Propane",8:"Electric",9:"Bifuel gasoline",12:"Bifuel LPG"][value] ?? String(format: "0x%02X", value)
    }
    private static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1000 { return String(format: "%.0f", value) }
        if magnitude >= 100 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

final class DiagnosticSessionRecorder: ObservableObject {
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var lastExportURLs: [URL] = []
    private var transcriptHandle: FileHandle?
    private var csvHandle: FileHandle?
    private var eventsHandle: FileHandle?
    private var startedAt: Date?
    private var label = ""
    private var fuelMode: FuelMode = .unknown

    func begin(label: String, fuelMode: FuelMode, metadata: [String:String]) {
        finish(summary: [:])
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OBDBridgeSessions", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent("\(formatter.string(from: Date()))-\(label.replacingOccurrences(of: " ", with: "-"))", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcriptURL = directory.appendingPathComponent("raw-transcript.txt")
        let csvURL = directory.appendingPathComponent("samples.csv")
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        fm.createFile(atPath: transcriptURL.path, contents: nil); fm.createFile(atPath: csvURL.path, contents: nil); fm.createFile(atPath: eventsURL.path, contents: nil)
        transcriptHandle = try? FileHandle(forWritingTo: transcriptURL); csvHandle = try? FileHandle(forWritingTo: csvURL); eventsHandle = try? FileHandle(forWritingTo: eventsURL)
        write(csv: "timestamp,elapsed_s,fuel_mode,scenario,command,pid,name,value,unit,raw\n")
        currentDirectory = directory; startedAt = Date(); self.label = label; self.fuelMode = fuelMode
        var payload = metadata; payload["scenario"] = label; payload["fuelMode"] = fuelMode.rawValue; payload["startedAt"] = ISO8601DateFormatter().string(from: Date())
        writeJSONEvent(type: "session_start", fields: payload); marker("Session started: \(label), fuel=\(fuelMode.rawValue)")
    }

    func setFuelMode(_ mode: FuelMode) { fuelMode = mode; marker("Fuel mode: \(mode.rawValue)") }
    func marker(_ text: String) { write(transcript: "[\(timestamp())] MARKER \(text)\n"); writeJSONEvent(type: "marker", fields: ["text":text]) }
    func command(_ command: String, response: String, timedOut: Bool) { writeJSONEvent(type: "command", fields: ["command":command,"response":response,"timedOut":timedOut ? "true":"false"]) }
    func raw(_ text: String) { write(transcript: text) }
    func sample(command: String, decoded: DecodedPID) {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let row = [ISO8601DateFormatter().string(from: Date()),String(format: "%.3f", elapsed),fuelMode.rawValue,label,command,String(format: "%02X", decoded.pid),decoded.name,decoded.value,decoded.unit,decoded.raw].map(csvEscape).joined(separator: ",") + "\n"
        write(csv: row)
    }
    func finish(summary: [String:String]) {
        guard let directory = currentDirectory else { return }
        var payload = summary; payload["endedAt"] = ISO8601DateFormatter().string(from: Date()); payload["scenario"] = label; payload["fuelMode"] = fuelMode.rawValue
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: directory.appendingPathComponent("summary.json"), options: .atomic) }
        writeJSONEvent(type: "session_end", fields: payload)
        try? transcriptHandle?.synchronize(); try? csvHandle?.synchronize(); try? eventsHandle?.synchronize(); try? transcriptHandle?.close(); try? csvHandle?.close(); try? eventsHandle?.close()
        transcriptHandle = nil; csvHandle = nil; eventsHandle = nil
        lastExportURLs = [directory.appendingPathComponent("summary.json"),directory.appendingPathComponent("samples.csv"),directory.appendingPathComponent("raw-transcript.txt"),directory.appendingPathComponent("events.jsonl")].filter { FileManager.default.fileExists(atPath: $0.path) }
        currentDirectory = nil; startedAt = nil
    }
    private func timestamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
    private func write(transcript: String) { if let data = transcript.data(using: .utf8) { try? transcriptHandle?.write(contentsOf: data) } }
    private func write(csv: String) { if let data = csv.data(using: .utf8) { try? csvHandle?.write(contentsOf: data) } }
    private func writeJSONEvent(type: String, fields: [String:String]) {
        var payload = fields; payload["type"] = type; payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n"); try? eventsHandle?.write(contentsOf: Data(line.utf8))
    }
    private func csvEscape(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))\"" }
}
