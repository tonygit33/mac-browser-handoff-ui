import Foundation

/// High-throughput, read-only acquisition plans for OBDLink MX+.
///
/// MX+ exposes one active interpreter/vehicle channel. The planner therefore does not claim
/// true parallel bus access. It maximizes throughput with serialized batches, adapter-side
/// ISO-TP receive segmentation, bounded monitoring, request coalescing and zero artificial
/// gaps between commands.
enum OBDLinkFastScanPlanner {
    enum PlanStatus: String {
        case implemented
        case vehicleConfirmed
        case requiresVehicleValidation
        case blocked
    }

    struct Plan {
        let id: String
        let name: String
        let summary: String
        let bus: String
        let commands: [String]
        let status: PlanStatus
        let risk: String
        let expectedUse: String

        var payload: [String: Any] {
            [
                "id": id,
                "name": name,
                "summary": summary,
                "bus": bus,
                "commands": commands,
                "status": status.rawValue,
                "risk": risk,
                "expectedUse": expectedUse,
                "executable": !commands.isEmpty && commands.allSatisfy(ReadOnlyCommandPolicy.isAllowed)
            ]
        }
    }

    static let adapterInspectionCommands = [
        "ATE0", "ATL0", "ATS1", "ATH1", "ATAL",
        "ATI", "STI", "STDI", "STIX", "STDIX", "STMFR",
        "ATRV", "STVR", "STVRX", "ATDP", "ATDPN", "STPR", "STPRS", "STPBRR"
    ]

    static let standardDiscoveryCommands: [String] = {
        var commands = ["ATE0", "ATL0", "ATS1", "ATH1", "ATAL", "ATSP0"]
        for base in stride(from: 0, through: 0xE0, by: 0x20) {
            commands.append(String(format: "01%02X", base))
        }
        commands += [
            "0101", "0102", "03", "07", "0A",
            "020000", "020200",
            "0900", "0902", "0904", "0906", "090A"
        ]
        for base in stride(from: 0, through: 0xE0, by: 0x20) {
            commands.append(String(format: "06%02X", base))
        }
        return commands
    }()

    static let plans: [Plan] = [
        Plan(
            id: "mxplus-inspection-fast",
            name: "MX+ inspection · fast batch",
            summary: "Read hardware, firmware, voltage, active protocol and actual baud rate in one serialized native queue.",
            bus: "adapter",
            commands: adapterInspectionCommands,
            status: .implemented,
            risk: "readOnly",
            expectedUse: "Run once per connection and persist results with every diagnostic session."
        ),
        Plan(
            id: "sae-discovery-fast",
            name: "SAE discovery · fast batch",
            summary: "Discover standard PIDs, freeze-frame support, DTC classes, vehicle identity and Mode 06 monitors without application-side delays.",
            bus: "auto",
            commands: standardDiscoveryCommands,
            status: .implemented,
            risk: "readOnly",
            expectedUse: "Initial vehicle baseline before Mazda enhanced module scans."
        ),
        Plan(
            id: "hs-can-passive-1000",
            name: "HS-CAN passive capture · 1,000 frames",
            summary: "Bounded passive monitor with headers and long messages enabled. No raw transmit command is present.",
            bus: "HS-CAN candidate 500 kbit/s",
            commands: ["ATH1", "ATAL", "STMA1000"],
            status: .vehicleConfirmed,
            risk: "passiveMonitor",
            expectedUse: "Correlate Mazda5 powertrain, ABS and steering CAN-ID candidates."
        ),
        Plan(
            id: "pcm-uds-identity",
            name: "PCM UDS identity reads",
            summary: "Use confirmed PCM 7E0/7E8 addressing to request common identification DIDs through service 22.",
            bus: "HS-CAN",
            commands: [
                "ATE0", "ATL0", "ATS1", "ATH1", "ATAL", "ATSP6",
                "ATSH7E0", "ATCRA7E8",
                "22F190", "22F187", "22F188", "22F18C"
            ],
            status: .vehicleConfirmed,
            risk: "readOnly",
            expectedUse: "Identify VIN/software/calibration fields where supported; negative responses are evidence, not errors."
        ),
        Plan(
            id: "mazda-ms-can-discovery",
            name: "Mazda MS-CAN discovery",
            summary: "MX+ supports Mazda/Ford MS-CAN, but the exact Mazda5 CR ST protocol and DLC routing must be validated before native execution.",
            bus: "MS-CAN candidate 125 kbit/s",
            commands: [],
            status: .requiresVehicleValidation,
            risk: "transportSelection",
            expectedUse: "Instrument cluster, BCM, sliding-door, HVAC and display discovery after exact transport confirmation."
        )
    ]

    static var performancePayload: [String: Any] {
        [
            "physicalParallelism": 1,
            "strategy": "single-channel serialized pipeline",
            "maximumNativeBatch": 128,
            "optimizations": [
                "no artificial inter-command delay",
                "command coalescing by request header",
                "adapter-side ISO-TP receive segmentation",
                "bounded passive monitoring",
                "frequency-aware live-data scheduler",
                "persisted supported-PID discovery",
                "separate HS-CAN and MS-CAN phases"
            ],
            "notSupported": [
                "simultaneous HS-CAN and MS-CAN sessions through one MX+",
                "simultaneous commands to several ECUs",
                "unbounded monitor-all capture",
                "write-service pipelining"
            ],
            "reason": "The STN interpreter and vehicle interface expose one active command/response channel. Concurrent writes would interleave responses and can corrupt ISO-TP state."
        ]
    }

    static func plan(id: String) -> Plan? {
        plans.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func readDIDCommands(requestHeader: String, responseHeader: String, did: String) -> [String]? {
        let request = cleanHex(requestHeader)
        let response = cleanHex(responseHeader)
        let identifier = cleanHex(did)
        guard request.count == 3, response.count == 3, identifier.count == 4 else { return nil }
        return [
            "ATE0", "ATL0", "ATS1", "ATH1", "ATAL", "ATSP6",
            "ATSH\(request)", "ATCRA\(response)", "22\(identifier)"
        ]
    }

    static func boundedMonitorCommands(count: Int) -> [String]? {
        guard (1...5_000).contains(count) else { return nil }
        return ["ATH1", "ATAL", "STMA\(count)"]
    }

    static func validate(_ commands: [String]) -> [String] {
        commands.filter { !ReadOnlyCommandPolicy.isAllowed($0) }
    }

    private static func cleanHex(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "0X", with: "")
            .filter { $0.isHexDigit }
    }
}
