import Darwin
import Foundation

public struct RemoteSSHSession: Equatable {
    public var destination: String
    public var port: Int?
    public var identityFile: String?
    public var configFile: String?
    public var jumpHost: String?
    public var controlPath: String?
    public var useIPv4: Bool
    public var useIPv6: Bool
    public var forwardAgent: Bool
    public var compressionEnabled: Bool
    public var sshOptions: [String]

    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        configFile: String? = nil,
        jumpHost: String? = nil,
        controlPath: String? = nil,
        useIPv4: Bool = false,
        useIPv6: Bool = false,
        forwardAgent: Bool = false,
        compressionEnabled: Bool = false,
        sshOptions: [String] = []
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.configFile = configFile
        self.jumpHost = jumpHost
        self.controlPath = controlPath
        self.useIPv4 = useIPv4
        self.useIPv6 = useIPv6
        self.forwardAgent = forwardAgent
        self.compressionEnabled = compressionEnabled
        self.sshOptions = sshOptions
    }

    public func hasSSHOptionKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sshOptions.contains { option in
            option
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first
                .map { String($0).lowercased() == lowered } ?? false
        }
    }
}

public struct ActiveSSHSession: Equatable {
    public var pid: Int32
    public var tty: String
    public var session: RemoteSSHSession

    public init(pid: Int32, tty: String, session: RemoteSSHSession) {
        self.pid = pid
        self.tty = tty
        self.session = session
    }
}

public enum SSHSessionDetectionError: Error, LocalizedError, Equatable {
    case noTTY
    case noForegroundSSH(String)
    case unreadableArguments(Int32)

    public var errorDescription: String? {
        switch self {
        case .noTTY:
            return "No controlling TTY. Pass --dest, or pass --tty for a terminal that is running ssh."
        case .noForegroundSSH(let tty):
            return "No foreground ssh process was found for \(tty)."
        case .unreadableArguments(let pid):
            return "Could not read process arguments for pid \(pid)."
        }
    }
}

public struct ProcessSnapshot: Equatable {
    public var pid: Int32
    public var pgid: Int32
    public var tpgid: Int32
    public var tty: String
    public var executableName: String

    public init(pid: Int32, pgid: Int32, tpgid: Int32, tty: String, executableName: String) {
        self.pid = pid
        self.pgid = pgid
        self.tpgid = tpgid
        self.tty = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executableName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SSHSessionDetector {
    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")

    public static func detectCurrentForegroundSSH() throws -> RemoteSSHSession {
        guard let tty = currentTTYName() else { throw SSHSessionDetectionError.noTTY }
        return try detectForegroundSSH(forTTY: tty)
    }

    public static func detectForegroundSSH(forTTY ttyName: String) throws -> RemoteSSHSession {
        let normalizedTTY = normalizeTTYName(ttyName)
        let candidates = processSnapshots(forTTY: normalizedTTY)
            .filter { isForegroundSSHProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let arguments = commandLineArguments(forPID: candidate.pid) else {
                throw SSHSessionDetectionError.unreadableArguments(candidate.pid)
            }
            if let session = parseSSHCommandLine(arguments) {
                return session
            }
        }
        throw SSHSessionDetectionError.noForegroundSSH(normalizedTTY)
    }

    public static func detectActiveInteractiveSSHSessions() -> [ActiveSSHSession] {
        detectActiveInteractiveSSHSessions(
            processes: allProcessSnapshots(),
            argumentsForPID: commandLineArguments(forPID:)
        )
    }

    public static func detectActiveInteractiveSSHSessionsForTesting(
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> [ActiveSSHSession] {
        detectActiveInteractiveSSHSessions(
            processes: processes,
            argumentsForPID: { argumentsByPID[$0] }
        )
    }

    public static func detectForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> RemoteSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        let candidates = processes
            .filter { isForegroundSSHProcess($0, ttyName: normalizedTTY) }
            .sorted { $0.pid > $1.pid }

        for candidate in candidates {
            guard let arguments = argumentsByPID[candidate.pid],
                  let session = parseSSHCommandLine(arguments) else {
                continue
            }
            return session
        }
        return nil
    }

    private static func detectActiveInteractiveSSHSessions(
        processes: [ProcessSnapshot],
        argumentsForPID: (Int32) -> [String]?
    ) -> [ActiveSSHSession] {
        var seen: Set<String> = []
        return processes
            .filter(isInteractiveSSHProcess)
            .sorted { lhs, rhs in
                if lhs.tty != rhs.tty { return lhs.tty < rhs.tty }
                return lhs.pid > rhs.pid
            }
            .compactMap { process in
                guard let arguments = argumentsForPID(process.pid),
                      let session = parseSSHCommandLine(arguments) else {
                    return nil
                }
                let key = sessionIdentityKey(session)
                guard seen.insert(key).inserted else { return nil }
                return ActiveSSHSession(pid: process.pid, tty: process.tty, session: session)
            }
    }

    public static func parseSSHCommandLine(_ arguments: [String]) -> RemoteSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if normalizedExecutableName(arguments[0]) == "ssh" {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var useIPv4 = false
        var useIPv6 = false
        var forwardAgent = false
        var compressionEnabled = false
        var sshOptions: [String] = []

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            switch option {
            case "p":
                guard let parsedPort = Int(trimmed) else { return false }
                port = parsedPort
            case "i":
                identityFile = trimmed
            case "F":
                configFile = trimmed
            case "J":
                jumpHost = trimmed
            case "S":
                controlPath = trimmed
            case "l":
                loginName = trimmed
            case "o":
                sshOptions.append(trimmed)
            default:
                return true
            }
            return true
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                if index < arguments.count {
                    destination = arguments[index]
                }
                break
            }

            guard argument.hasPrefix("-"), argument != "-" else {
                destination = argument
                break
            }

            if argument.hasPrefix("-o"), argument.count > 2 {
                let value = String(argument.dropFirst(2))
                guard consumeValue(value, for: "o") else { return nil }
                index += 1
                continue
            }

            let optionText = String(argument.dropFirst())
            var optionIndex = optionText.startIndex
            while optionIndex < optionText.endIndex {
                let option = optionText[optionIndex]
                let nextIndex = optionText.index(after: optionIndex)

                if noArgumentFlags.contains(option) {
                    switch option {
                    case "4":
                        useIPv4 = true
                        useIPv6 = false
                    case "6":
                        useIPv6 = true
                        useIPv4 = false
                    case "A":
                        forwardAgent = true
                    case "C":
                        compressionEnabled = true
                    default:
                        break
                    }
                    optionIndex = nextIndex
                    continue
                }

                guard valueArgumentFlags.contains(option) else {
                    return nil
                }

                let value: String
                if nextIndex < optionText.endIndex {
                    value = String(optionText[nextIndex...])
                } else {
                    index += 1
                    guard index < arguments.count else { return nil }
                    value = arguments[index]
                }
                guard consumeValue(value, for: option) else { return nil }
                optionIndex = optionText.endIndex
            }
            index += 1
        }

        guard var resolvedDestination = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedDestination.isEmpty else {
            return nil
        }
        if let loginName, !resolvedDestination.contains("@") {
            resolvedDestination = "\(loginName)@\(resolvedDestination)"
        }

        return RemoteSSHSession(
            destination: resolvedDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions
        )
    }

    public static func sshArguments(command: String, session: RemoteSSHSession) -> [String] {
        var args = [
            "-T",
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
            args += ["-p", String(port)]
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
        args += [session.destination, command]
        return args
    }

    private static func currentTTYName() -> String? {
        guard let pointer = ttyname(STDIN_FILENO) else { return nil }
        return String(cString: pointer)
    }

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func normalizedExecutableName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private static func isForegroundSSHProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            process.executableName.lowercased() == "ssh" &&
            process.pgid > 0 &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func isInteractiveSSHProcess(_ process: ProcessSnapshot) -> Bool {
        process.executableName.lowercased() == "ssh" &&
            process.tty != "??" &&
            !process.tty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sessionIdentityKey(_ session: RemoteSSHSession) -> String {
        [
            session.destination,
            session.port.map(String.init) ?? "",
            session.identityFile ?? "",
            session.configFile ?? "",
            session.jumpHost ?? "",
            session.controlPath ?? "",
            session.useIPv4 ? "4" : "",
            session.useIPv6 ? "6" : "",
            session.forwardAgent ? "A" : "",
            session.compressionEnabled ? "C" : "",
            session.sshOptions.joined(separator: "\u{1f}")
        ].joined(separator: "\u{1e}")
    }

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func allProcessSnapshots() -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }
        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).lowercased()
        )
    }

    private static func commandLineArguments(forPID pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }

        return parseKernProcArgs(Array(buffer.prefix(Int(size))))
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(4))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = 4
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            while index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }

        return arguments.count == argc ? arguments : nil
    }
}
