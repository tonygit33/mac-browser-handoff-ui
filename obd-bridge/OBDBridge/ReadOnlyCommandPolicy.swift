import Foundation

enum ReadOnlyCommandPolicy {
    static let allowedOBDServices: Set<String> = ["01", "02", "03", "06", "07", "09", "0A"]

    private static let safeAdapterCommands: Set<String> = [
        "ATI", "ATRV", "ATDP", "ATDPN", "ATH0", "ATH1", "ATS0", "ATS1",
        "ATL0", "ATL1", "ATE0", "ATE1", "ATSP0", "ATZ", "STI", "STDI",
        "STIX", "STDIX", "STMFR", "STPR", "STPRS", "STPBRR", "STVR"
    ]

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func isAllowed(_ rawCommand: String) -> Bool {
        let command = normalize(rawCommand)
        guard !command.isEmpty else { return false }

        if command.range(of: "^[0-9A-F]+$", options: .regularExpression) != nil,
           command.count >= 2 {
            return allowedOBDServices.contains(String(command.prefix(2)))
        }

        if safeAdapterCommands.contains(command) { return true }

        // Passive STN monitor commands are read-only. A trailing decimal limit is required
        // so broad or malformed ST commands cannot reach the adapter through the terminal.
        return command.range(of: "^STM(A)?[0-9]+$", options: .regularExpression) != nil
    }
}
