import Foundation

/// Structured OBDNative API 1.1 router.
///
/// This router is intentionally separate from WebKit plumbing. NativeWebBridge can delegate
/// supported methods here. All vehicle commands still pass through ReadOnlyCommandPolicy.
/// Programming methods expose catalog and preparation data only; execute is hard-rejected.
enum OBDNativeV11Router {
    enum RouterError: LocalizedError {
        case unknownMethod(String)
        case missingParameter(String)
        case notConnected
        case invalidValue(String)
        case blocked(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unknownMethod(let method): return "Unknown OBDNative 1.1 method: \(method)"
            case .missingParameter(let name): return "Missing parameter: \(name)"
            case .notConnected: return "OBDLink MX+ is not connected"
            case .invalidValue(let message): return message
            case .blocked(let message): return message
            case .unavailable(let message): return message
            }
        }
    }

    static let methods = [
        "capabilities.get",
        "profiles.list",
        "profiles.apply",
        "adapter.inspect",
        "scan.performance",
        "scan.fastDiscovery",
        "monitor.capture",
        "transport.readDID",
        "programming.catalog",
        "programming.prepare",
        "programming.execute"
    ]

    static func handles(_ method: String) -> Bool {
        methods.contains(method)
    }

    @MainActor
    static func handle(method: String, params: [String: Any], bridge: AccessoryBridge) throws -> [String: Any] {
        switch method {
        case "capabilities.get":
            return [
                "apiVersion": OBDLinkCapabilityCatalog.apiVersion,
                "policyVersion": OBDLinkCapabilityCatalog.policyVersion,
                "capabilities": OBDLinkCapabilityCatalog.capabilities,
                "modules": OBDLinkCapabilityCatalog.moduleCandidates,
                "performance": OBDLinkFastScanPlanner.performancePayload,
                "programmingSummary": programmingSummary()
            ]

        case "profiles.list":
            return [
                "profiles": OBDLinkCapabilityCatalog.profiles.map(\.payload),
                "fastPlans": OBDLinkFastScanPlanner.plans.map(\.payload)
            ]

        case "profiles.apply":
            guard bridge.isConnected else { throw RouterError.notConnected }
            guard let id = params["id"] as? String else { throw RouterError.missingParameter("id") }
            if let profile = OBDLinkCapabilityCatalog.profile(id: id) {
                guard !profile.commands.isEmpty else {
                    throw RouterError.unavailable("Profile \(id) is documented but not executable yet")
                }
                try enqueue(profile.commands, bridge: bridge)
                return ["accepted": profile.commands.count, "profile": profile.payload]
            }
            if let plan = OBDLinkFastScanPlanner.plan(id: id) {
                guard !plan.commands.isEmpty else {
                    throw RouterError.unavailable("Plan \(id) requires vehicle validation before execution")
                }
                try enqueue(plan.commands, bridge: bridge)
                return ["accepted": plan.commands.count, "profile": plan.payload]
            }
            throw RouterError.invalidValue("Unknown profile: \(id)")

        case "adapter.inspect":
            guard bridge.isConnected else { throw RouterError.notConnected }
            try enqueue(OBDLinkFastScanPlanner.adapterInspectionCommands, bridge: bridge)
            return [
                "accepted": OBDLinkFastScanPlanner.adapterInspectionCommands.count,
                "commands": OBDLinkFastScanPlanner.adapterInspectionCommands,
                "strategy": "single serialized native queue"
            ]

        case "scan.performance":
            return OBDLinkFastScanPlanner.performancePayload

        case "scan.fastDiscovery":
            guard bridge.isConnected else { throw RouterError.notConnected }
            try enqueue(OBDLinkFastScanPlanner.standardDiscoveryCommands, bridge: bridge)
            return [
                "accepted": OBDLinkFastScanPlanner.standardDiscoveryCommands.count,
                "plan": "sae-discovery-fast",
                "parallelism": 1,
                "delivery": "serialized queue with no artificial gaps"
            ]

        case "monitor.capture":
            guard bridge.isConnected else { throw RouterError.notConnected }
            let count = intValue(params["count"]) ?? 200
            guard let commands = OBDLinkFastScanPlanner.boundedMonitorCommands(count: count) else {
                throw RouterError.invalidValue("Monitor count must be from 1 to 5000")
            }
            try enqueue(commands, bridge: bridge)
            return [
                "accepted": commands.count,
                "messageCount": count,
                "mode": "boundedPassiveMonitor",
                "commands": commands
            ]

        case "transport.readDID":
            guard bridge.isConnected else { throw RouterError.notConnected }
            guard let request = params["requestHeader"] as? String else { throw RouterError.missingParameter("requestHeader") }
            guard let response = params["responseHeader"] as? String else { throw RouterError.missingParameter("responseHeader") }
            guard let did = params["did"] as? String else { throw RouterError.missingParameter("did") }
            guard let commands = OBDLinkFastScanPlanner.readDIDCommands(requestHeader: request, responseHeader: response, did: did) else {
                throw RouterError.invalidValue("Expected 3-hex request/response headers and a 4-hex DID")
            }
            try enqueue(commands, bridge: bridge)
            return [
                "accepted": commands.count,
                "service": "22",
                "did": did.uppercased(),
                "commands": commands,
                "delivery": "response is emitted through the normal native log stream"
            ]

        case "programming.catalog":
            return [
                "modules": MazdaProgrammingCatalog.modulesPayload,
                "executionAvailable": false,
                "policy": OBDLinkCapabilityCatalog.policyVersion
            ]

        case "programming.prepare":
            guard let id = params["operationID"] as? String else { throw RouterError.missingParameter("operationID") }
            guard let payload = MazdaProgrammingCatalog.preparationPayload(id: id) else {
                throw RouterError.invalidValue("Unknown programming operation: \(id)")
            }
            return payload

        case "programming.execute":
            throw RouterError.blocked(
                "Programming execution is not exposed by OBDNative. Only read and preparation workflows are available."
            )

        default:
            throw RouterError.unknownMethod(method)
        }
    }

    @MainActor
    private static func enqueue(_ commands: [String], bridge: AccessoryBridge) throws {
        let blocked = commands.filter { !ReadOnlyCommandPolicy.isAllowed($0) }
        guard blocked.isEmpty else {
            throw RouterError.blocked("Native read-only policy blocked: \(blocked.joined(separator: ", "))")
        }
        commands.forEach(bridge.send)
    }

    private static func programmingSummary() -> [String: Any] {
        let grouped = Dictionary(grouping: MazdaProgrammingCatalog.operations, by: { $0.writeState.rawValue })
        return [
            "operations": MazdaProgrammingCatalog.operations.count,
            "byState": grouped.mapValues(\.count),
            "executionAvailable": false
        ]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
