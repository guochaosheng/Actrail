import Foundation

struct DiagnosticLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let tag: String
    let message: String
    let callStack: String

    init(tag: String, message: String, callStack: String = "") {
        self.id = UUID()
        self.timestamp = Date()
        self.tag = tag
        self.message = message
        self.callStack = callStack
    }
}

enum DiagnosticLog {
    private static let maxEntries = 100
    private static let key = "com.actrail.diagnosticLog"

    static func append(tag: String, message: String, includeCallStack: Bool = true) {
        var entries = load()
        let stack = includeCallStack
            ? Thread.callStackSymbols
                .dropFirst(2)
                .prefix(6)
                .joined(separator: "\n  → ")
            : ""
        entries.insert(DiagnosticLogEntry(tag: tag, message: message, callStack: stack), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        print("[Diag][\(tag)] \(f.string(from: Date())) \(message)")
    }

    static func load() -> [DiagnosticLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([DiagnosticLogEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ entries: [DiagnosticLogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
