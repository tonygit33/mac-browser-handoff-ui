import Foundation

/// Native, versioned description of the OBDLink MX+ surface exposed to the hosted web UI.
///
/// The catalog deliberately separates four states:
/// - implemented: the native application has a dedicated workflow;
/// - lowLevel: the operation is reachable through the read-only command API;
/// - planned: the adapter supports it, but the native Mazda workflow is not implemented;
/// - blocked: the hardware may support it, but the production bridge must not transmit it.
enum OBDLinkCapabilityCatalog {
    static let apiVersion = "1.1"
    static let policyVersion = "native-read-only-v3"

    struct Profile {
        let id: String
        let name: String
        let summary: String
        let commands: [String]
        let status: String
        let risk: String
        let requiresConnection: Bool

        var payload: [String: Any] {
            [
                "id": id,
                "name": name,
                "summary": summary,
                "commands": commands,
                "status": status,
                "risk": risk,
                "requiresConnection": requiresConnection,
                "applicable": !commands.isEmpty
            ]
        }
    }

    static let profiles: [Profile] = [
        Profile(
            id: "adapter-identity",
            name: "Adapter identity",
            summary: "Read ELM compatibility, STN firmware, OBDLink hardware revision, extended device data and manufacturer.",
            commands: ["ATI", "STI", "STDI", "STIX", "STDIX", "STMFR"],
            status: "implemented",
            risk: "readOnly",
            requiresConnection: true
        ),
        Profile(
            id: "protocol-identity",
            name: "Active protocol",
            summary: "Read the currently selected protocol number, description and actual baud rate without changing the vehicle bus.",
            commands: ["ATDP", "ATDPN", "STPR", "STPRS", "STPBRR"],
            status: "implemented",
            risk: "readOnly",
            requiresConnection: true
        ),
        Profile(
            id: "voltage-health",
            name: "Voltage health",
            summary: "Read vehicle supply voltage through both ELM-compatible and STN-native commands, plus raw ADC steps.",
            commands: ["ATRV", "STVR", "STVRX"],
            status: "implemented",
            risk: "readOnly",
            requiresConnection: true
        ),
        Profile(
            id: "standard-obd-auto",
            name: "Standard OBD auto setup",
            summary: "Reset volatile output formatting, show headers, allow long responses and use automatic OBD protocol detection.",
            commands: ["ATE0", "ATL0", "ATS1", "ATH1", "ATAL", "ATSP0"],
            status: "implemented",
            risk: "volatileAdapterConfiguration",
            requiresConnection: true
        ),
        Profile(
            id: "passive-can-200",
            name: "Passive CAN capture · 200 frames",
            summary: "Bounded monitor-all capture with headers enabled. The adapter is interrupted automatically when the count or timeout is reached.",
            commands: ["ATH1", "ATAL", "STMA200"],
            status: "implemented",
            risk: "passiveMonitor",
            requiresConnection: true
        ),
        Profile(
            id: "passive-can-1000",
            name: "Passive CAN capture · 1,000 frames",
            summary: "Longer bounded passive capture for candidate CAN-ID correlation. No transmit command is included.",
            commands: ["ATH1", "ATAL", "STMA1000"],
            status: "implemented",
            risk: "passiveMonitor",
            requiresConnection: true
        ),
        Profile(
            id: "mazda-ms-can-discovery",
            name: "Mazda MS-CAN discovery",
            summary: "Hardware capability is present on MX+, but an exact Mazda5 CR protocol/pin-routing profile has not yet been promoted to native code.",
            commands: [],
            status: "planned",
            risk: "requiresVehicleValidation",
            requiresConnection: true
        )
    ]

    static var methods: [String] {
        [
            "bridge.info", "state.get", "capabilities.get", "profiles.list", "profiles.apply",
            "accessories.refresh", "adapter.connect", "adapter.disconnect", "adapter.inspect",
            "command.validate", "command.send", "command.batch", "monitor.capture", "transport.readDID",
            "scan.snapshot", "scan.start", "scan.stop", "session.marker", "session.setFuelMode",
            "log.get", "log.clear", "files.list", "files.readChunk", "files.writeText", "files.delete",
            "files.share", "clipboard.write", "haptics.impact", "app.setKeepAwake", "app.openExternal", "app.reload"
        ]
    }

    static var capabilities: [String: Any] {
        [
            "adapter": [
                capability("identity", "Adapter identity and firmware", "implemented", "readOnly"),
                capability("voltage", "Supply voltage and raw ADC", "implemented", "readOnly"),
                capability("protocol", "Current protocol and baud inspection", "implemented", "readOnly"),
                capability("powerSave", "PowerSave state/configuration", "lowLevel", "adapterConfiguration"),
                capability("firmwareUpdate", "Adapter firmware update", "blocked", "persistentWrite")
            ],
            "vehicleProtocols": [
                capability("iso15765", "ISO 15765-4 / Classical CAN", "implemented", "readOnly"),
                capability("rawCan", "Raw ISO 11898 CAN monitoring", "implemented", "passiveMonitor"),
                capability("msCan", "Ford/Mazda MS-CAN hardware", "planned", "requiresVehicleValidation"),
                capability("kwp2000", "ISO 14230 KWP2000", "lowLevel", "vehicleApplicabilityUnknown"),
                capability("iso9141", "ISO 9141", "lowLevel", "vehicleApplicabilityUnknown"),
                capability("swCan", "Single-wire CAN / GMLAN", "notApplicable", "notMazdaMSCAN"),
                capability("j1850", "J1850 PWM/VPW", "notApplicable", "vehicleApplicabilityUnknown"),
                capability("j1939", "SAE J1939", "notApplicable", "vehicleApplicabilityUnknown")
            ],
            "diagnostics": [
                capability("mode01", "Mode 01 live data", "implemented", "readOnly"),
                capability("mode02", "Mode 02 freeze frame", "implemented", "readOnly"),
                capability("mode03", "Mode 03 stored DTC", "implemented", "readOnly"),
                capability("mode06", "Mode 06 monitor results", "implemented", "readOnly"),
                capability("mode07", "Mode 07 pending DTC", "implemented", "readOnly"),
                capability("mode09", "Mode 09 VIN/calibration data", "implemented", "readOnly"),
                capability("mode0A", "Mode 0A permanent DTC", "implemented", "readOnly"),
                capability("uds19", "UDS service 19 read DTC information", "lowLevel", "readOnly"),
                capability("uds22", "UDS service 22 read data by identifier", "implemented", "readOnly"),
                capability("moduleDiscovery", "Addressed Mazda module discovery", "planned", "requiresVehicleValidation")
            ],
            "transport": [
                capability("headers", "CAN headers and response addressing", "lowLevel", "volatileAdapterConfiguration"),
                capability("filters", "Pass/block receive filters", "lowLevel", "readSideConfiguration"),
                capability("rxSegmentation", "ISO-TP receive segmentation", "lowLevel", "transportConfiguration"),
                capability("flowControl", "Automatic flow-control configuration", "lowLevel", "mayTransmitFlowControl"),
                capability("txSegmentation", "ISO-TP transmit segmentation", "blocked", "transmitCapability"),
                capability("arbitraryTransmit", "STPX arbitrary transmit", "blocked", "rawTransmit")
            ],
            "serviceFunctions": [
                capability("clearDTC", "Clear diagnostic information", "blocked", "vehicleStateChange"),
                capability("actuators", "Active tests and actuator control", "blocked", "vehicleActuation"),
                capability("coding", "Module coding and As-Built writes", "blocked", "configurationWrite"),
                capability("security", "Security access and key programming", "blocked", "securityCritical"),
                capability("flashing", "ECU/module programming", "blocked", "flashWrite")
            ],
            "storage": [
                capability("files", "Persistent transcripts and diagnostic exports", "implemented", "localStorage"),
                capability("chunks", "Chunked file reads for web upload", "implemented", "localRead"),
                capability("analysis", "AI evidence snapshot upload", "implemented", "explicitUpload")
            ]
        ]
    }

    static let moduleCandidates: [[String: Any]] = [
        module("PCM", "7E0", "7E8", "vehicleConfirmed"),
        module("TCM", "7E1", "7E9", "candidate"),
        module("ABS", "760", "768", "candidate"),
        module("Instrument Cluster", "720", "728", "candidate"),
        module("BCM/BEM", "726", "72E", "candidate"),
        module("Audio Control Module", "727", "72F", "candidate"),
        module("HVAC/HIM", "733", "73B", "candidate"),
        module("Parking Aid Module", "736", "73E", "candidate")
    ]

    static func profile(id: String) -> Profile? {
        profiles.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func commandDescription(_ rawCommand: String) -> [String: Any] {
        let command = ReadOnlyCommandPolicy.normalize(rawCommand)
        let allowed = ReadOnlyCommandPolicy.isAllowed(command)
        let category: String
        let risk: String

        if command.hasPrefix("STMA") || command.hasPrefix("STM") || command == "ATMA" {
            category = "passiveMonitor"
            risk = "passiveRead"
        } else if command.range(of: #"^[0-9A-F]+$"#, options: .regularExpression) != nil {
            category = "diagnosticService"
            risk = allowed ? "readOnly" : "blocked"
        } else if ["ATI", "STI", "STDI", "STIX", "STDIX", "STMFR", "ATRV", "STVR", "STVRX", "ATDP", "ATDPN", "STPR", "STPRS", "STPBRR"].contains(command) {
            category = "adapterInspection"
            risk = "readOnly"
        } else {
            category = "adapterSessionConfiguration"
            risk = allowed ? "volatileConfiguration" : "blocked"
        }

        return [
            "command": command,
            "allowed": allowed,
            "category": category,
            "risk": risk,
            "policy": policyVersion
        ]
    }

    private static func capability(_ id: String, _ name: String, _ status: String, _ risk: String) -> [String: Any] {
        ["id": id, "name": name, "status": status, "risk": risk]
    }

    private static func module(_ name: String, _ request: String, _ response: String, _ status: String) -> [String: Any] {
        ["name": name, "requestHeader": request, "responseHeader": response, "status": status, "executable": false]
    }
}
