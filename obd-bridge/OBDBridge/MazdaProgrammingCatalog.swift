import Foundation

/// Text-first catalog for Mazda5 CR read/configure/program surfaces.
///
/// The catalog intentionally exposes a program button state to the web UI while keeping
/// execution unavailable. An item can be shown as a candidate without providing a payload.
/// Exact request bytes, security algorithms, checksums and write procedures are not promoted
/// until they are confirmed for the target module part number and recovery has been validated.
enum MazdaProgrammingCatalog {
    enum WriteState: String {
        case prepareOnly
        case researchOnly
        case safetyBlocked
        case securityBlocked
        case unsupportedByMXPlus
    }

    struct Operation {
        let id: String
        let module: String
        let category: String
        let title: String
        let currentValueLabel: String
        let readCommands: [String]
        let readStatus: String
        let writeState: WriteState
        let risk: String
        let evidence: String
        let prerequisites: [String]
        let description: String

        var payload: [String: Any] {
            [
                "id": id,
                "module": module,
                "category": category,
                "title": title,
                "currentValueLabel": currentValueLabel,
                "readCommands": readCommands,
                "readExecutable": !readCommands.isEmpty && readCommands.allSatisfy(ReadOnlyCommandPolicy.isAllowed),
                "readStatus": readStatus,
                "writeState": writeState.rawValue,
                "writeExecutable": false,
                "risk": risk,
                "evidence": evidence,
                "prerequisites": prerequisites,
                "description": description
            ]
        }
    }

    static let operations: [Operation] = [
        Operation(
            id: "pcm-identification",
            module: "PCM",
            category: "identity",
            title: "PCM identification and calibration",
            currentValueLabel: "VIN / calibration / software identifiers",
            readCommands: ["ATSP6", "ATH1", "ATAL", "ATSH7E0", "ATCRA7E8", "22F190", "22F187", "22F188", "22F18C"],
            readStatus: "vehicleConfirmedAddress",
            writeState: .researchOnly,
            risk: "high",
            evidence: "PCM 7E0/7E8 is confirmed on the vehicle; individual DID support must be measured.",
            prerequisites: ["Stable battery support", "Exact PCM part number", "Original calibration backup", "Recovery-capable wired VCI for flashing"],
            description: "Read identifiers now. Firmware programming remains a separately researched operation and is not executed through the web bridge."
        ),
        Operation(
            id: "pcm-adaptive-memory",
            module: "PCM",
            category: "adaptation",
            title: "PCM adaptive memory reset",
            currentValueLabel: "Fuel trims and learned idle state",
            readCommands: ["0106", "0107", "010C", "010D", "0111"],
            readStatus: "standardOBD",
            writeState: .prepareOnly,
            risk: "medium",
            evidence: "A reset procedure exists in professional tooling, but the exact Mazda5 service and prerequisites are not promoted.",
            prerequisites: ["Engine fault causes repaired", "Warm-up procedure documented", "Vehicle stationary", "Post-reset relearn plan"],
            description: "The UI may prepare a checklist and capture before/after evidence. No reset command is transmitted."
        ),
        Operation(
            id: "tcm-configuration",
            module: "TCM",
            category: "configuration",
            title: "Transmission configuration and adaptive reset",
            currentValueLabel: "TCM identity and transmission state",
            readCommands: [],
            readStatus: "candidateAddress7E1_7E9",
            writeState: .researchOnly,
            risk: "high",
            evidence: "Address pair is a related-platform candidate and is not vehicle-confirmed.",
            prerequisites: ["Confirm TCM presence", "Confirm request/response headers", "Transmission temperature limits", "Relearn route"],
            description: "Read and programming controls stay unavailable until the actual Mazda5 TCM topology is confirmed."
        ),
        Operation(
            id: "abs-bleed",
            module: "ABS/DSC",
            category: "serviceRoutine",
            title: "ABS hydraulic bleed routine",
            currentValueLabel: "ABS DTC and wheel-speed evidence",
            readCommands: [],
            readStatus: "candidateAddress760_768",
            writeState: .safetyBlocked,
            risk: "critical",
            evidence: "Professional scanners expose ABS bleed, but no exact Mazda5 CR routine payload is confirmed.",
            prerequisites: ["Correct brake service procedure", "Fluid level monitoring", "Vehicle secured", "Exact ABS module part number"],
            description: "Visible as a capability candidate only. Actuation is blocked because it operates hydraulic valves and pump."
        ),
        Operation(
            id: "sasm-zero-point",
            module: "SASM/ABS",
            category: "calibration",
            title: "Steering-angle zero-point calibration",
            currentValueLabel: "Steering angle and calibration state",
            readCommands: [],
            readStatus: "candidate",
            writeState: .prepareOnly,
            risk: "high",
            evidence: "Calibration is plausible on the platform; exact module address and routine are unverified.",
            prerequisites: ["Wheels straight", "Level surface", "Correct tire pressures", "No active steering/ABS faults"],
            description: "The page can collect preconditions and readings. Routine execution remains unavailable."
        ),
        Operation(
            id: "ic-illumination-options",
            module: "Instrument Cluster",
            category: "configuration",
            title: "Cluster illumination and warning options",
            currentValueLabel: "Cluster identity and configured options",
            readCommands: [],
            readStatus: "candidateAddress720_728",
            writeState: .researchOnly,
            risk: "medium",
            evidence: "The cluster is an HS/MS gateway on Mazda5 CR, but exact configuration blocks are not mapped.",
            prerequisites: ["Read complete original configuration", "Confirm cluster part number", "Byte-level checksum understanding"],
            description: "Potentially programmable options are shown, but raw Mazda3/Ford As-Built layouts are not reused."
        ),
        Operation(
            id: "bcm-auto-lock",
            module: "BCM/GEM",
            category: "configuration",
            title: "Automatic door locking",
            currentValueLabel: "Current auto-lock setting",
            readCommands: [],
            readStatus: "msCanTransportPending",
            writeState: .researchOnly,
            risk: "medium",
            evidence: "BCM is documented on MS-CAN; the exact Mazda5 CR configuration identifier is not confirmed.",
            prerequisites: ["Validated MS-CAN profile", "Original BCM configuration backup", "All doors operational", "Confirmed option encoding"],
            description: "Read-current and Program buttons are part of the UI. Both remain non-executable until exact MS-CAN transport and identifier are validated."
        ),
        Operation(
            id: "bcm-courtesy-lamp-delay",
            module: "BCM/GEM",
            category: "configuration",
            title: "Courtesy-lamp delay",
            currentValueLabel: "Current lamp delay",
            readCommands: [],
            readStatus: "msCanTransportPending",
            writeState: .researchOnly,
            risk: "medium",
            evidence: "Body and lamp state candidates exist, but no exact writable Mazda5 parameter is confirmed.",
            prerequisites: ["Validated MS-CAN profile", "BCM backup", "Confirmed units/range", "Ignition-state procedure"],
            description: "A good example of the requested read-next-to-program workflow; program execution remains gated."
        ),
        Operation(
            id: "bcm-headlamp-behavior",
            module: "BCM/GEM",
            category: "configuration",
            title: "Exterior-lamp behavior",
            currentValueLabel: "Current lighting configuration",
            readCommands: [],
            readStatus: "msCanTransportPending",
            writeState: .researchOnly,
            risk: "high",
            evidence: "Lighting options vary by market and hardware. No exact configuration block is confirmed.",
            prerequisites: ["Market and lamp hardware identified", "Original configuration backup", "Legal applicability checked"],
            description: "Includes candidates such as lamp delay or DRL behavior, not a ready write procedure."
        ),
        Operation(
            id: "lpsdm-initialization",
            module: "LPSDM",
            category: "calibration",
            title: "Left sliding-door initialization",
            currentValueLabel: "Door position, latch and learned limits",
            readCommands: [],
            readStatus: "officialCoverageVehicleUnverified",
            writeState: .prepareOnly,
            risk: "high",
            evidence: "OBDLink coverage lists the module family for Mazda5, but addresses and routines are not published.",
            prerequisites: ["Clear doorway", "Known-good mechanical system", "Battery support", "Emergency stop procedure"],
            description: "Read state and prepare initialization. Motor actuation is blocked until the exact routine is confirmed."
        ),
        Operation(
            id: "rpsdm-initialization",
            module: "RPSDM",
            category: "calibration",
            title: "Right sliding-door initialization",
            currentValueLabel: "Door position, latch and learned limits",
            readCommands: [],
            readStatus: "officialCoverageVehicleUnverified",
            writeState: .prepareOnly,
            risk: "high",
            evidence: "OBDLink coverage lists the module family for Mazda5, but addresses and routines are not published.",
            prerequisites: ["Clear doorway", "Known-good mechanical system", "Battery support", "Emergency stop procedure"],
            description: "Symmetric workflow to the left door; no motor command is exposed."
        ),
        Operation(
            id: "hvac-actuator-calibration",
            module: "HVAC/HIM",
            category: "calibration",
            title: "HVAC actuator calibration",
            currentValueLabel: "Door positions and temperature sensors",
            readCommands: [],
            readStatus: "candidateAddress733_73B",
            writeState: .prepareOnly,
            risk: "medium",
            evidence: "Module address is a related-platform candidate; vehicle equipment varies.",
            prerequisites: ["Confirm automatic/manual HVAC type", "Confirm address", "No obstructed blend doors"],
            description: "The interface can pair current positions with a calibration button, but actuation remains gated."
        ),
        Operation(
            id: "audio-display-text",
            module: "Audio/Display",
            category: "activeBroadcast",
            title: "Display text injection",
            currentValueLabel: "Current display/audio state",
            readCommands: [],
            readStatus: "passiveCanCandidates290_291",
            writeState: .researchOnly,
            risk: "medium",
            evidence: "0x290/0x291 are adjacent-platform MS-CAN candidates, not confirmed Mazda5 transmit frames.",
            prerequisites: ["Passive capture confirmation", "Correct counter/timing", "Stationary bench or isolated test"],
            description: "Shown as an experimental active broadcast, not normal module programming."
        ),
        Operation(
            id: "rcm-write-functions",
            module: "RCM/SRS",
            category: "safetyConfiguration",
            title: "Airbag module configuration or reset",
            currentValueLabel: "Read-only DTC and module identity",
            readCommands: [],
            readStatus: "addressConflict",
            writeState: .safetyBlocked,
            risk: "critical",
            evidence: "Source address conflict is unresolved and the module is safety-critical.",
            prerequisites: ["Factory procedure", "Correct replacement-state rules", "Qualified SRS service environment"],
            description: "No reset, coding or calibration command is exposed."
        ),
        Operation(
            id: "ocs-calibration",
            module: "OCS",
            category: "safetyCalibration",
            title: "Occupant-classification calibration",
            currentValueLabel: "Read-only OCS status",
            readCommands: [],
            readStatus: "makeWideCoverageOnly",
            writeState: .safetyBlocked,
            risk: "critical",
            evidence: "Coverage is make-wide and not Mazda5-specific.",
            prerequisites: ["Factory weights and fixtures", "Exact seat/OCS hardware", "Factory calibration procedure"],
            description: "Calibration remains unavailable because an incorrect result changes airbag deployment logic."
        ),
        Operation(
            id: "pats-key-programming",
            module: "PATS/RKE",
            category: "security",
            title: "Key and immobilizer programming",
            currentValueLabel: "Registered-key count and module identity",
            readCommands: [],
            readStatus: "makeWideCoverageOnly",
            writeState: .securityBlocked,
            risk: "critical",
            evidence: "PATS/RKE coverage does not provide authorized Mazda5 procedures or security algorithms.",
            prerequisites: ["Proof of ownership", "Authorized security procedure", "All keys present", "Recovery path"],
            description: "Security Access and key enrollment are intentionally outside the web bridge."
        ),
        Operation(
            id: "module-firmware-programming",
            module: "All programmable ECUs",
            category: "flashing",
            title: "Firmware programming",
            currentValueLabel: "Part number, software version and calibration",
            readCommands: [],
            readStatus: "metadataIncomplete",
            writeState: .unsupportedByMXPlus,
            risk: "critical",
            evidence: "MX+ has historical programming capability, but Bluetooth reliability, FEPS requirements and recovery differ by module.",
            prerequisites: ["Exact firmware file", "Checksum/signature validation", "Stable programming supply", "Wired recovery-capable VCI", "Bench recovery plan"],
            description: "The page inventories programmability, but normal firmware writing is not enabled through the iPhone/MX+ web shell."
        )
    ]

    static var modulesPayload: [[String: Any]] {
        let grouped = Dictionary(grouping: operations, by: \.module)
        return grouped.keys.sorted().map { module in
            [
                "module": module,
                "operations": grouped[module, default: []].map(\.payload)
            ]
        }
    }

    static func operation(id: String) -> Operation? {
        operations.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func preparationPayload(id: String) -> [String: Any]? {
        guard let item = operation(id: id) else { return nil }
        return [
            "operation": item.payload,
            "executionAllowed": false,
            "nativePolicy": OBDLinkCapabilityCatalog.policyVersion,
            "steps": [
                "Read current value and module identity",
                "Save original configuration and evidence",
                "Verify exact module part number and transport",
                "Verify voltage and ignition preconditions",
                "Require a reviewed write procedure and rollback path",
                "Execute only from a future native expert gate"
            ],
            "message": "Preparation is available. Write execution is intentionally not implemented."
        ]
    }
}
