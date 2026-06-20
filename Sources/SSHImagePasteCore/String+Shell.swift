import Foundation

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var shellEscaped: String {
        if isEmpty {
            return "''"
        }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return self
        }
        return shellSingleQuoted
    }

    var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
