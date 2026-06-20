import Foundation

public enum RemoteUploadError: Error, LocalizedError, Equatable {
    case noFiles
    case invalidLocalFile(URL)
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFiles:
            return "No files to upload."
        case .invalidLocalFile(let url):
            return "Not a readable local file: \(url.path)"
        case .uploadFailed(let detail):
            return "scp upload failed: \(detail)"
        }
    }
}

public struct RemoteUploader {
    public var runner: CommandRunner

    public init(runner: CommandRunner = .live) {
        self.runner = runner
    }

    public func upload(
        _ files: [URL],
        to session: RemoteSSHSession,
        remotePaths requestedRemotePaths: [String]? = nil
    ) throws -> [String] {
        guard !files.isEmpty else { throw RemoteUploadError.noFiles }
        if let requestedRemotePaths, requestedRemotePaths.count != files.count {
            throw RemoteUploadError.uploadFailed("remote path count did not match file count")
        }

        var remotePaths: [String] = []
        do { 
            for (index, file) in files.enumerated() {
                let normalized = file.standardizedFileURL
                guard normalized.isFileURL,
                      let values = try? normalized.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    throw RemoteUploadError.invalidLocalFile(file)
                }

                let remotePath = requestedRemotePaths?[index] ?? Self.remoteDropPath(for: normalized)
                let result = try runner.run(
                    "/usr/bin/scp",
                    Self.scpArguments(localPath: normalized.path, remotePath: remotePath, session: session),
                    45
                )
                guard result.status == 0 else {
                    let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "scp exited \(result.status)"
                    throw RemoteUploadError.uploadFailed(detail)
                }
                remotePaths.append(remotePath)
            }
            return remotePaths
        } catch {
            cleanup(remotePaths, session: session)
            throw error
        }
    }

    public static func remoteDropPath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        let ext = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        return "/tmp/cmux-drop-\(uuid.uuidString.lowercased())\(suffix)"
    }

    public static func scpArguments(localPath: String, remotePath: String, session: RemoteSSHSession) -> [String] {
        var args = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no"
        ]

        if session.useIPv4 {
            args.append("-4")
        } else if session.useIPv6 {
            args.append("-6")
        }
        if session.forwardAgent {
            args.append("-A")
        }
        if session.compressionEnabled {
            args.append("-C")
        }
        if let configFile = session.configFile, !configFile.isBlank {
            args += ["-F", configFile]
        }
        if let jumpHost = session.jumpHost, !jumpHost.isBlank {
            args += ["-J", jumpHost]
        }
        if let port = session.port {
            args += ["-P", String(port)]
        }
        if let identityFile = session.identityFile, !identityFile.isBlank {
            args += ["-i", identityFile]
        }
        if let controlPath = session.controlPath,
           !controlPath.isBlank,
           !session.hasSSHOptionKey("ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !session.hasSSHOptionKey("StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in session.sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(scpRemoteDestination(session.destination)):\(remotePath)"]
        return args
    }

    private func cleanup(_ remotePaths: [String], session: RemoteSSHSession) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(\.shellSingleQuoted).joined(separator: " ")
        let command = "sh -c \(cleanupScript.shellSingleQuoted)"
        _ = try? runner.run(
            "/usr/bin/ssh",
            SSHSessionDetector.sshArguments(command: command, session: session),
            8
        )
    }

    private static func scpRemoteDestination(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmed
        }

        guard hostPart.contains(":"),
              !hostPart.hasPrefix("["),
              !hostPart.hasSuffix("]") else {
            return trimmed
        }

        if let userPart {
            return "\(userPart)@[\(hostPart)]"
        }
        return "[\(hostPart)]"
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
