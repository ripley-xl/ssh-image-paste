import Foundation

public enum RemoteClipboardError: Error, LocalizedError, Equatable {
    case noRemotePaths
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRemotePaths:
            return "No remote files were uploaded."
        case .writeFailed(let detail):
            return "Remote clipboard write failed: \(detail)"
        }
    }
}

public struct RemoteClipboardWriter {
    public var runner: CommandRunner

    public init(runner: CommandRunner = .live) {
        self.runner = runner
    }

    public func writeImagePaths(
        _ remotePaths: [String],
        session: RemoteSSHSession,
        remoteHelperPath: String? = nil
    ) throws {
        guard !remotePaths.isEmpty else { throw RemoteClipboardError.noRemotePaths }

        for remotePath in remotePaths {
            let mimeType = Self.mimeType(forRemotePath: remotePath)
            let command: String
            if let remoteHelperPath, !remoteHelperPath.isBlank {
                command = "python3 \(Self.remoteHelperCommandPath(remoteHelperPath)) write-image \(remotePath.shellEscaped) --mime \(mimeType.shellEscaped)"
            } else {
                let script = Self.remoteClipboardScript(path: remotePath, mimeType: mimeType)
                command = "sh -lc \(script.shellSingleQuoted)"
            }
            let result = try runner.run(
                "/usr/bin/ssh",
                SSHSessionDetector.sshArguments(command: command, session: session),
                12
            )
            guard result.status == 0 else {
                let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
                throw RemoteClipboardError.writeFailed(detail)
            }
        }
    }

    public static func remoteClipboardScript(path: String, mimeType: String) -> String {
        """
        set -eu
        path=\(path.shellSingleQuoted)
        mime=\(mimeType.shellSingleQuoted)
        if command -v wl-copy >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
          wl-copy --type "$mime" < "$path"
        elif command -v xclip >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
          xclip -selection clipboard -t "$mime" -i "$path"
        elif command -v osascript >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
          osascript "$path" <<'OSA'
        on run argv
          set imageFile to POSIX file (item 1 of argv)
          set the clipboard to (read imageFile as «class PNGf»)
        end run
        OSA
        else
          echo "no remote image clipboard backend found; install wl-copy or xclip, or start the helper from a desktop session" >&2
          exit 127
        fi
        """
    }

    public static func mimeType(forRemotePath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "tiff", "tif":
            return "image/tiff"
        case "bmp":
            return "image/bmp"
        default:
            return "image/png"
        }
    }

    public static func remoteHelperCommandPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return "\"$HOME\""
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return "\"$HOME/\(shellDoubleQuotedLiteral(suffix))\""
        }
        return trimmed.shellEscaped
    }

    private static func shellDoubleQuotedLiteral(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        return escaped
    }

    private func bestErrorLine(stderr: String, stdout: String) -> String? {
        for text in [stderr, stdout] {
            if let line = text
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return line
            }
        }
        return nil
    }
}
