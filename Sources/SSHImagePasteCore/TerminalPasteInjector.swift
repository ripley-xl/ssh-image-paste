import Darwin
import Foundation

public enum TerminalPasteInjectionError: Error, LocalizedError, Equatable {
    case invalidTTY(String)
    case openFailed(String, Int32)
    case injectFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidTTY(let tty):
            return "Invalid TTY: \(tty)"
        case .openFailed(let path, let errnoValue):
            return "Could not open \(path): \(String(cString: strerror(errnoValue)))"
        case .injectFailed(let path, let errnoValue):
            return "Could not inject input into \(path): \(String(cString: strerror(errnoValue)))"
        }
    }
}

public struct TerminalPasteInjector {
    public init() {}

    public func injectBracketedPaste(_ text: String, intoTTY tty: String) throws {
        let path = try Self.devicePath(forTTY: tty)
        let fd = open(path, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw TerminalPasteInjectionError.openFailed(path, errno)
        }
        defer { close(fd) }

        for byte in Self.bracketedPasteBytes(for: text) {
            var mutableByte = byte
            guard ioctl(fd, UInt(TIOCSTI), &mutableByte) == 0 else {
                throw TerminalPasteInjectionError.injectFailed(path, errno)
            }
        }
    }

    public static func bracketedPasteBytes(for text: String) -> [UInt8] {
        Array("\u{1B}[200~\(text)\u{1B}[201~".utf8)
    }

    public static func devicePath(forTTY tty: String) throws -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else {
            throw TerminalPasteInjectionError.invalidTTY(tty)
        }
        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }
        guard !trimmed.contains("/") else {
            throw TerminalPasteInjectionError.invalidTTY(tty)
        }
        return "/dev/\(trimmed)"
    }
}
