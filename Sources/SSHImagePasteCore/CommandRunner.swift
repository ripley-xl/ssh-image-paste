import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandRunnerError: Error, LocalizedError, Equatable, Sendable {
    case timedOut(String, TimeInterval)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout)) seconds."
        case .launchFailed(let executable):
            return "Failed to launch \(executable)."
        }
    }
}

public struct CommandRunner: Sendable {
    public var run: @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandResult

    public init(run: @escaping @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandResult) {
        self.run = run
    }

    public static let live = CommandRunner { executable, arguments, timeout in
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                process.interrupt()
            }
            throw CommandRunnerError.timedOut(executable, timeout)
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
