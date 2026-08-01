import Foundation

enum ReadOnlyCommandPolicy {
    static let allowedDiagnosticServices: Set<String> = [
        "01", "02", "03", "06", "07", "09", "0A", "19", "22"
    ]

    private static let maximumCommandLength = 160
    private static let maximumMonitorMessages = 5_000

    private static let safeExactAdapterCommands: Set<String> = [
        "ATI", "AT@1", "AT@2", "ATRV", "ATDP", "ATDPN", "ATCS", "ATKW",
        "ATIGN", "ATAMC", "ATPPS", "STI", "STIX", "STDI", "STDIX", "STMFR",
        "STSN", "STVR", "STVRX", "STPR", "STPRS", "STPBRR", "STCTRR",
        "STSLCS", "STSLLT", "STSLXS", "STBTI", "STBTIX", "STGPIR", "STGPIH",
        "STGPOR", "STCALSTAT", "STDICES", "STDICPO", "STDITPO", "ATD0", "ATD1",
        "ATZ", "ATWS", "ATD", "ATPC", "ATSP0", "ATTP0", "ATAL", "ATNL",
        "ATMA", "STPC", "STP0"
    ]

    private static let safeSessionPatterns: [String] = [
        #"^AT(?:E|L|S|H|R)[01]$"#,
        #"^ATAT[0-2]$"#,
        #"^ATST[0-9A-F]{2}$"#,
        #"^ATSP[0-9A-C]$"#,
        #"^ATTP[0-9A-C]$"#,
        #"^ATSH[0-9A-F]{3,8}$"#,
        #"^ATCRA[0-9A-F]{3,8}$"#,
        #"^ATCF[0-9A-F]{3,8}$"#,
        #"^ATCM[0-9A-F]{3,8}$"#,
        #"^ATCP[0-9A-F]{2}$"#,
        #"^ATTA[0-9A-F]{2}$"#,
        #"^AT(?:CAF|CFC|DLC|V)[01]$"#,
        #"^ATFC(?:SH|SD|SM)[0-9A-F]{1,16}$"#,
        #"^ATIB(?:10|48|96)$"#,
        #"^ATSW[0-9A-F]{2}$"#,
        #"^ATWM[0-9A-F]{1,12}$"#,
        #"^STP[0-9A-F]{1,2}$"#,
        #"^STPBR[0-9A-F]{2,8}$"#,
        #"^STPTO[0-9A-F]{1,4}$"#,
        #"^STCTM[0-9A-F]{1,4}$"#,
        #"^STCAF[0-2]$"#,
        #"^STCFC[01]$"#,
        #"^STCSEGR[01]$"#,
        #"^STCSEGRT[0-9A-F]{1,4}$"#,
        #"^STCSEG[0-9A-F]{1,8}$"#,
        #"^STFAP[0-9A-F]{3,8},[0-9A-F]{3,8}$"#,
        #"^STFCP[0-9A-F]{3,8},[0-9A-F]{3,8}$"#,
        #"^STFCSH[0-9A-F]{3,8}$"#,
        #"^STFCSD[0-9A-F]{1,16}$"#,
        #"^STFCSM[0-2]$"#,
        #"^STFPA[0-9A-F]{3,8}$"#,
        #"^STFRA[0-9A-F]{3,8}$"#,
        #"^STFT[0-9A-F]{3,8}$"#,
        #"^STFAC$"#,
        #"^STCFCP$"#,
        #"^STFFCA$"#,
        #"^STP(?:WM|BR|TO)[0-9A-F]{1,8}$"#
    ]

    private static let explicitlyBlockedPrefixes = [
        "04", "08", "10", "11", "14", "27", "28", "2E", "2F", "31", "34",
        "35", "36", "37", "38", "3D", "3E", "85",
        "STPX", "STPP", "STPPS", "STPPC", "STPPA", "STPPT",
        "STBTN", "STBTCOD", "STBTP", "STBTDN", "STBTPT", "STBTSC",
        "STWBR", "STNVM", "STFW", "STBOOT", "STIAP", "STGPOW", "ATPP"
    ]

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    static func isAllowed(_ rawCommand: String) -> Bool {
        let command = normalize(rawCommand)
        guard !command.isEmpty, command.count <= maximumCommandLength else { return false }
        guard command.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        guard !explicitlyBlockedPrefixes.contains(where: command.hasPrefix) else { return false }

        if command.range(of: #"^[0-9A-F]+$"#, options: .regularExpression) != nil,
           command.count >= 2 {
            return allowedDiagnosticServices.contains(String(command.prefix(2)))
        }

        if safeExactAdapterCommands.contains(command) { return true }
        if safeSessionPatterns.contains(where: { matches(pattern: $0, value: command) }) { return true }

        if let match = command.range(of: #"^STMA?(\d+)$"#, options: .regularExpression) {
            let digits = command[match].filter(\.isNumber)
            if let count = Int(digits), (1...maximumMonitorMessages).contains(count) { return true }
        }
        return false
    }

    private static func matches(pattern: String, value: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }
}
