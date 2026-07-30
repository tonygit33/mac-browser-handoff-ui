import Foundation

extension SignalIdentifierV1 {
    /// A requirement may omit signalID or ECU address to match all signals decoded from a request.
    func matchesRequirement(_ requirement: SignalIdentifierV1) -> Bool {
        guard namespace.caseInsensitiveCompare(requirement.namespace) == .orderedSame,
              service.caseInsensitiveCompare(requirement.service) == .orderedSame,
              identifier.caseInsensitiveCompare(requirement.identifier) == .orderedSame else {
            return false
        }

        if let requiredECU = requirement.ecuAddress,
           ecuAddress?.caseInsensitiveCompare(requiredECU) != .orderedSame {
            return false
        }
        if let requiredSignalID = requirement.signalID,
           signalID?.caseInsensitiveCompare(requiredSignalID) != .orderedSame {
            return false
        }
        return true
    }
}

extension DiagnosticCapabilityReportV1 {
    func supports(_ requirement: SignalIdentifierV1) -> Bool {
        supportedSignals.isEmpty || supportedSignals.contains { candidate in
            candidate.matchesRequirement(requirement) || requirement.matchesRequirement(candidate)
        }
    }
}
