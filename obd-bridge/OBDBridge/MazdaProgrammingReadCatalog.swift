import Foundation

/// Read-side companion to MazdaProgrammingCatalog.
///
/// Every risky operation gets a concrete read plan, even when the exact writable DID/routine
/// is still unknown. Plans are classified as direct, candidate-confirmed, passive correlation,
/// or plan-only. Only commands accepted by ReadOnlyCommandPolicy can ever be queued.
enum MazdaProgrammingReadCatalog {
    enum Mode: String {
        case direct
        case candidateConfirmation
        case passiveCorrelation
        case transportDiscovery
        case planOnly
    }

    struct Plan {
        let operationID: String
        let title: String
        let mode: Mode
        let bus: String
        let target: String
        let commands: [String]
        let expectedValues: [String]
        let passiveCANIDs: [String]
        let evidence: String
        let requiresExplicitConfirmation: Bool

        var executable: Bool {
            !commands.isEmpty && commands.allSatisfy(ReadOnlyCommandPolicy.isAllowed)
        }

        var payload: [String: Any] {
            [
                "operationID": operationID,
                "title": title,
                "mode": mode.rawValue,
                "bus": bus,
                "target": target,
                "commands": commands,
                "expectedValues": expectedValues,
                "passiveCANIDs": passiveCANIDs,
                "evidence": evidence,
                "requiresExplicitConfirmation": requiresExplicitConfirmation,
                "executable": executable,
                "writeExecutable": false
            ]
        }
    }

    static let plans: [Plan] = [
        Plan(
            operationID: "pcm-identification",
            title: "Read PCM identity and calibration before any programming research",
            mode: .direct,
            bus: "HS-CAN / ISO 15765-4",
            target: "PCM 7E0 -> 7E8",
            commands: ["ATSP6", "ATH1", "ATAL", "ATSH7E0", "ATCRA7E8", "22F190", "22F187", "22F188", "22F18C"],
            expectedValues: ["VIN", "ECU part number", "software number", "calibration identifier"],
            passiveCANIDs: [],
            evidence: "PCM diagnostic address is confirmed on the vehicle; individual DID support remains response-driven.",
            requiresExplicitConfirmation: false
        ),
        Plan(
            operationID: "pcm-adaptive-memory",
            title: "Capture the learned state before preparing an adaptive reset",
            mode: .direct,
            bus: "Standard OBD on HS-CAN",
            target: "Functional emissions diagnostics",
            commands: ["0106", "0107", "010C", "010D", "0111", "0104", "0105", "010B"],
            expectedValues: ["STFT", "LTFT", "RPM", "speed", "throttle", "load", "coolant", "MAP"],
            passiveCANIDs: [],
            evidence: "All commands are standard read-only SAE PIDs already supported by the native decoder.",
            requiresExplicitConfirmation: false
        ),
        Plan(
            operationID: "tcm-configuration",
            title: "Confirm TCM presence and read identity before configuration research",
            mode: .candidateConfirmation,
            bus: "HS-CAN candidate",
            target: "TCM 7E1 -> 7E9",
            commands: ["ATSP6", "ATH1", "ATAL", "ATSH7E1", "ATCRA7E9", "22F190", "22F187", "22F188", "1902FF"],
            expectedValues: ["TCM presence", "identity", "software/calibration", "DTC summary"],
            passiveCANIDs: ["0x228", "0x231"],
            evidence: "Address pair is a related-platform candidate and must be explicitly confirmed by the user before queueing.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "abs-bleed",
            title: "Read ABS identity, DTC and wheel evidence before bleed research",
            mode: .candidateConfirmation,
            bus: "HS-CAN candidate",
            target: "ABS 760 -> 768",
            commands: ["ATSP6", "ATH1", "ATAL", "ATSH760", "ATCRA768", "22F190", "22F187", "1902FF", "STMA200"],
            expectedValues: ["ABS identity", "DTC information", "wheel-speed activity"],
            passiveCANIDs: ["0x4B0"],
            evidence: "Address and wheel-speed broadcast are candidates; no hydraulic actuation is included.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "sasm-zero-point",
            title: "Read steering-angle evidence before zero-point calibration research",
            mode: .passiveCorrelation,
            bus: "HS-CAN passive plus ABS candidate",
            target: "SASM/ABS relationship",
            commands: ["ATSP6", "ATH1", "ATAL", "STMA500"],
            expectedValues: ["steering angle movement", "center repeatability", "related ABS state"],
            passiveCANIDs: ["0x4DA"],
            evidence: "Passive angle frame is an adjacent-platform candidate; no RoutineControl command is present.",
            requiresExplicitConfirmation: false
        ),
        Plan(
            operationID: "ic-illumination-options",
            title: "Read cluster identity and passive display state before coding research",
            mode: .candidateConfirmation,
            bus: "HS-CAN candidate / gateway",
            target: "Instrument Cluster 720 -> 728",
            commands: ["ATSP6", "ATH1", "ATAL", "ATSH720", "ATCRA728", "22F190", "22F187", "22F188", "1902FF", "STMA200"],
            expectedValues: ["cluster identity", "software/calibration", "DTC summary", "display activity"],
            passiveCANIDs: ["0x400", "0x401", "0x4F2"],
            evidence: "Cluster is documented as a network gateway; exact configuration blocks are not mapped.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "bcm-auto-lock",
            title: "Observe door and lock state before auto-lock coding research",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "BCM/GEM; candidate 726 -> 72E",
            commands: [],
            expectedValues: ["door states", "lock state", "ignition state", "vehicle speed trigger"],
            passiveCANIDs: ["0x433", "0x285", "0x201"],
            evidence: "The useful read surface is known, but exact Mazda5 MS-CAN selection/routing is not promoted yet.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "bcm-courtesy-lamp-delay",
            title: "Measure courtesy-lamp timing and BCM state before coding research",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "BCM/GEM; candidate 726 -> 72E",
            commands: [],
            expectedValues: ["door-open timestamps", "lamp-on timestamp", "lamp-off timestamp", "ignition state"],
            passiveCANIDs: ["0x433", "0x501", "0x511"],
            evidence: "Current value can first be measured behaviorally even before the writable configuration identifier is known.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "bcm-headlamp-behavior",
            title: "Read lighting state and market configuration evidence",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "BCM/GEM lighting configuration",
            commands: [],
            expectedValues: ["headlamp state", "DRL state", "ignition state", "market/hardware identity"],
            passiveCANIDs: ["0x433", "0x501"],
            evidence: "Lighting behavior is observable; exact configuration storage remains unknown and market-specific.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "lpsdm-initialization",
            title: "Read left sliding-door state before initialization research",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "LPSDM; exact diagnostic address unknown",
            commands: [],
            expectedValues: ["left door position", "latch state", "open/close command", "learned-limit status"],
            passiveCANIDs: ["0x433"],
            evidence: "The module family is in Mazda coverage, but request headers and DIDs are not published.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "rpsdm-initialization",
            title: "Read right sliding-door state before initialization research",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "RPSDM; exact diagnostic address unknown",
            commands: [],
            expectedValues: ["right door position", "latch state", "open/close command", "learned-limit status"],
            passiveCANIDs: ["0x433"],
            evidence: "The module family is in Mazda coverage, but request headers and DIDs are not published.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "hvac-actuator-calibration",
            title: "Read HVAC identity, temperatures and actuator positions",
            mode: .candidateConfirmation,
            bus: "CAN candidate; equipment-dependent",
            target: "HVAC/HIM 733 -> 73B",
            commands: ["ATSP6", "ATH1", "ATAL", "ATSH733", "ATCRA73B", "22F190", "22F187", "1902FF", "STMA200"],
            expectedValues: ["HVAC presence", "identity", "DTC summary", "temperature/actuator activity"],
            passiveCANIDs: ["0x2A0"],
            evidence: "Address is a related-platform candidate; operation is read-only and requires explicit confirmation.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "audio-display-text",
            title: "Observe audio/display state before active broadcast research",
            mode: .transportDiscovery,
            bus: "Mazda MS-CAN pending",
            target: "Audio/Display; candidate diagnostic 727 -> 72F",
            commands: [],
            expectedValues: ["audio source", "display text fragments", "display mode", "timing/counter behavior"],
            passiveCANIDs: ["0x28F", "0x290", "0x291", "0x401"],
            evidence: "Passive candidates exist, but transmit frame timing and counters are not confirmed for Mazda5.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "rcm-write-functions",
            title: "Collect read-only RCM identity and DTC evidence",
            mode: .planOnly,
            bus: "CAN address conflict unresolved",
            target: "RCM/SRS",
            commands: [],
            expectedValues: ["module identity", "part number", "DTC information", "replacement state"],
            passiveCANIDs: [],
            evidence: "A source-address conflict must be resolved before even addressed read requests are proposed.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "ocs-calibration",
            title: "Collect read-only occupant-classification status",
            mode: .planOnly,
            bus: "Module topology unconfirmed",
            target: "OCS",
            commands: [],
            expectedValues: ["module identity", "seat/occupant state", "DTC information", "calibration status"],
            passiveCANIDs: [],
            evidence: "Make-wide coverage only; no Mazda5-specific address or safe read route is confirmed.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "pats-key-programming",
            title: "Collect non-secret PATS/RKE identity and key-count evidence",
            mode: .planOnly,
            bus: "Security module topology unconfirmed",
            target: "PATS/RKE",
            commands: [],
            expectedValues: ["module identity", "registered-key count if openly readable", "DTC information"],
            passiveCANIDs: [],
            evidence: "No SecurityAccess, seed-key, key enrollment or secret material is requested or exposed.",
            requiresExplicitConfirmation: true
        ),
        Plan(
            operationID: "module-firmware-programming",
            title: "Inventory identities and software versions before firmware research",
            mode: .candidateConfirmation,
            bus: "Known and candidate CAN diagnostic addresses",
            target: "PCM, TCM, ABS, Cluster and BCM candidates",
            commands: [
                "ATSP6", "ATH1", "ATAL",
                "ATSH7E0", "ATCRA7E8", "22F190", "22F187", "22F188", "22F18C",
                "ATSH7E1", "ATCRA7E9", "22F190", "22F187", "22F188",
                "ATSH760", "ATCRA768", "22F190", "22F187",
                "ATSH720", "ATCRA728", "22F190", "22F187",
                "ATSP0"
            ],
            expectedValues: ["module presence", "part numbers", "software versions", "calibration identifiers"],
            passiveCANIDs: [],
            evidence: "This is inventory only. RequestDownload/TransferData and all firmware writes remain absent.",
            requiresExplicitConfirmation: true
        )
    ]

    static func plan(operationID: String) -> Plan? {
        plans.first { $0.operationID.caseInsensitiveCompare(operationID) == .orderedSame }
    }

    static func payload(operationID: String) -> [String: Any]? {
        plan(operationID: operationID)?.payload
    }
}
