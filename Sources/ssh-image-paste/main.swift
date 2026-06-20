import AppKit
import Foundation
import SSHImagePasteCore

struct CLIOptions {
    var destination: String?
    var tty: String?
    var port: Int?
    var identityFile: String?
    var configFile: String?
    var jumpHost: String?
    var sshOptions: [String] = []
    var remoteHelperPath: String?
    var copyPath = false
    var remoteClipboard = false
    var raw = false
}

enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

func parseOptions(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0

    func requireValue(for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError.usage("\(flag) requires a value.")
        }
        return arguments[index]
    }

    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--help", "-h":
            printUsageAndExit(0)
        case "--dest":
            options.destination = try requireValue(for: arg)
        case "--tty":
            options.tty = try requireValue(for: arg)
        case "--port", "-p":
            let value = try requireValue(for: arg)
            guard let port = Int(value) else {
                throw CLIError.usage("--port requires an integer.")
            }
            options.port = port
        case "--identity", "-i":
            options.identityFile = try requireValue(for: arg)
        case "--config", "-F":
            options.configFile = try requireValue(for: arg)
        case "--jump", "-J":
            options.jumpHost = try requireValue(for: arg)
        case "--ssh-option", "-o":
            options.sshOptions.append(try requireValue(for: arg))
        case "--copy-path":
            options.copyPath = true
        case "--remote-clipboard":
            options.remoteClipboard = true
        case "--remote-helper":
            options.remoteHelperPath = try requireValue(for: arg)
        case "--raw":
            options.raw = true
        default:
            if arg.hasPrefix("-") {
                throw CLIError.usage("Unknown option: \(arg)")
            }
            if options.destination == nil {
                options.destination = arg
            } else {
                throw CLIError.usage("Unexpected argument: \(arg)")
            }
        }
        index += 1
    }

    return options
}

func session(from options: CLIOptions) throws -> RemoteSSHSession {
    var session: RemoteSSHSession
    if let destination = options.destination {
        session = RemoteSSHSession(destination: destination)
    } else if let tty = options.tty {
        session = try SSHSessionDetector.detectForegroundSSH(forTTY: tty)
    } else {
        session = try SSHSessionDetector.detectCurrentForegroundSSH()
    }

    if let port = options.port {
        session.port = port
    }
    if let identityFile = options.identityFile {
        session.identityFile = identityFile
    }
    if let configFile = options.configFile {
        session.configFile = configFile
    }
    if let jumpHost = options.jumpHost {
        session.jumpHost = jumpHost
    }
    if !options.sshOptions.isEmpty {
        session.sshOptions.append(contentsOf: options.sshOptions)
    }
    return session
}

func printUsageAndExit(_ code: Int32) -> Never {
    let text = """
    Usage:
      ssh-image-paste [--dest user@host] [--tty /dev/ttys003] [options]

    Reads a local macOS clipboard image or file URL, uploads it to the foreground ssh
    session with scp, and prints the remote /tmp/cmux-drop-* path.

    Options:
      --dest, DEST          SSH destination. If omitted, detect foreground ssh on the TTY.
      --tty PATH            TTY to inspect, e.g. /dev/ttys003.
      -p, --port PORT       SSH port.
      -i, --identity PATH   Identity file.
      -F, --config PATH     SSH config file.
      -J, --jump HOST       Jump host.
      -o, --ssh-option OPT  Extra ssh/scp option. Repeatable.
      --remote-clipboard    Write uploaded image into the remote system clipboard.
      --remote-helper PATH   Remote helper path to use for clipboard writes.
      --copy-path           Copy the resulting remote path back to the local clipboard.
      --raw                 Print raw paths instead of shell-escaped paths.
      -h, --help            Show this help.
    """
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
    exit(code)
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let materializer = ClipboardImageMaterializer()
    let files = try materializer.materializeFilesFromGeneralPasteboard()
    defer { materializer.cleanupTemporaryFiles(files) }

    let resolvedSession = try session(from: options)
    let remotePaths = try RemoteUploader().upload(files.map(\.url), to: resolvedSession)
    if options.remoteClipboard {
        try RemoteClipboardWriter().writeImagePaths(
            remotePaths,
            session: resolvedSession,
            remoteHelperPath: options.remoteHelperPath
        )
    }
    let output = remotePaths
        .map { options.raw ? $0 : $0.shellEscaped }
        .joined(separator: " ")

    if options.copyPath {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
    print(output)
} catch let error as CLIError {
    fputs("error: \(error.localizedDescription)\n\n", stderr)
    printUsageAndExit(2)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
