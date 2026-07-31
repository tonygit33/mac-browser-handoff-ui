import Foundation

enum SessionFileNaming {
    static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        var result = String(mapped)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return result.isEmpty ? "session" : String(result.prefix(64))
    }

    static func directoryName(
        date: Date = Date(),
        label: String,
        identifier: String = String(UUID().uuidString.prefix(8))
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: date))-\(safeComponent(label))-\(safeComponent(identifier))"
    }
}
