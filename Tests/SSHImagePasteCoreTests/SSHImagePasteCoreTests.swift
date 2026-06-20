import AppKit
import Foundation
import Testing
@testable import SSHImagePasteCore

@Suite
struct SSHImagePasteCoreTests {
    @Test
    func parsesCommonSSHArguments() throws {
        let session = try #require(SSHSessionDetector.parseSSHCommandLine([
            "/usr/bin/ssh",
            "-A",
            "-C",
            "-p", "2222",
            "-i", "/Users/me/.ssh/id_ed25519",
            "-F", "/Users/me/.ssh/config",
            "-J", "relay@example.com",
            "-o", "ControlPath=/tmp/cmux-ssh-%C",
            "-l", "alice",
            "example.com"
        ]))

        #expect(session.destination == "alice@example.com")
        #expect(session.port == 2222)
        #expect(session.identityFile == "/Users/me/.ssh/id_ed25519")
        #expect(session.configFile == "/Users/me/.ssh/config")
        #expect(session.jumpHost == "relay@example.com")
        #expect(session.forwardAgent)
        #expect(session.compressionEnabled)
        #expect(session.sshOptions == ["ControlPath=/tmp/cmux-ssh-%C"])
    }

    @Test
    func parsesForegroundProcessSnapshot() throws {
        let session = try #require(SSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys003",
            processes: [
                ProcessSnapshot(pid: 10, pgid: 10, tpgid: 10, tty: "ttys003", executableName: "ssh"),
                ProcessSnapshot(pid: 9, pgid: 9, tpgid: 10, tty: "ttys003", executableName: "zsh")
            ],
            argumentsByPID: [
                10: ["ssh", "-p2022", "dev.example.com"]
            ]
        ))

        #expect(session.destination == "dev.example.com")
        #expect(session.port == 2022)
    }

    @Test
    func detectsAllInteractiveSSHSessionsAndDeduplicatesDestinations() throws {
        let sessions = SSHSessionDetector.detectActiveInteractiveSSHSessionsForTesting(
            processes: [
                ProcessSnapshot(pid: 10, pgid: 10, tpgid: 10, tty: "ttys001", executableName: "ssh"),
                ProcessSnapshot(pid: 11, pgid: 11, tpgid: 11, tty: "ttys002", executableName: " ssh             "),
                ProcessSnapshot(pid: 12, pgid: 12, tpgid: 12, tty: "??", executableName: "ssh"),
                ProcessSnapshot(pid: 13, pgid: 13, tpgid: 13, tty: "ttys003", executableName: "zsh"),
                ProcessSnapshot(pid: 14, pgid: 14, tpgid: 14, tty: "ttys004", executableName: "ssh")
            ],
            argumentsByPID: [
                10: ["ssh", "dev-a"],
                11: ["ssh", "-p", "2222", "dev-b"],
                12: ["ssh", "ignored-no-tty"],
                14: ["ssh", "dev-a"]
            ]
        )

        #expect(sessions.map(\.session.destination) == ["dev-a", "dev-b"])
        #expect(sessions.map(\.session.port) == [nil, 2222])
    }

    @Test
    func remoteDropPathPreservesLowercaseExtension() {
        let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let url = URL(fileURLWithPath: "/tmp/Screen Shot.PNG")
        #expect(RemoteUploader.remoteDropPath(for: url, uuid: uuid) == "/tmp/cmux-drop-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
    }

    @Test
    func scpArgumentsBracketIPv6Destination() {
        let session = RemoteSSHSession(destination: "alice@2001:db8::1", port: 2222)
        let args = RemoteUploader.scpArguments(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop.png",
            session: session
        )

        #expect(args.contains("-P"))
        #expect(args.contains("2222"))
        #expect(args.last == "alice@[2001:db8::1]:/tmp/cmux-drop.png")
    }

    @Test
    func shellEscapesWhitespaceAndQuotes() {
        #expect("/tmp/a.png".shellEscaped == "/tmp/a.png")
        #expect("/tmp/Screen Shot.png".shellEscaped == "'/tmp/Screen Shot.png'")
        #expect("/tmp/bob's.png".shellEscaped == "'/tmp/bob'\"'\"'s.png'")
    }

    @Test
    func bracketedPastePayloadWrapsTextForTerminalPaste() throws {
        let bytes = TerminalPasteInjector.bracketedPasteBytes(for: "/tmp/a.png")
        #expect(String(decoding: bytes, as: UTF8.self) == "\u{1B}[200~/tmp/a.png\u{1B}[201~")
        #expect(try TerminalPasteInjector.devicePath(forTTY: "ttys001") == "/dev/ttys001")
        #expect(try TerminalPasteInjector.devicePath(forTTY: "/dev/ttys002") == "/dev/ttys002")
    }

    @Test
    func uploadReturnsRemotePathFromRunner() throws {
        let recorder = InvocationRecorder()
        let uploader = RemoteUploader(runner: CommandRunner { executable, arguments, _ in
            recorder.append(executable: executable, arguments: arguments)
            return CommandResult(status: 0, stdout: "", stderr: "")
        })
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-clipboard-test-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let paths = try uploader.upload([fileURL], to: RemoteSSHSession(destination: "example.com"))

        #expect(paths.count == 1)
        #expect(paths[0].hasPrefix("/tmp/cmux-drop-"))
        #expect(paths[0].hasSuffix(".png"))
        let invocations = recorder.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations[0].0 == "/usr/bin/scp")
    }

    @Test
    func uploadCanUseCallerProvidedRemotePath() throws {
        let recorder = InvocationRecorder()
        let uploader = RemoteUploader(runner: CommandRunner { executable, arguments, _ in
            recorder.append(executable: executable, arguments: arguments)
            return CommandResult(status: 0, stdout: "", stderr: "")
        })
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-clipboard-fixed-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let paths = try uploader.upload(
            [fileURL],
            to: RemoteSSHSession(destination: "example.com"),
            remotePaths: ["/tmp/ssh-image-paste-fixed.png"]
        )

        #expect(paths == ["/tmp/ssh-image-paste-fixed.png"])
        #expect(recorder.snapshot()[0].1.last == "example.com:/tmp/ssh-image-paste-fixed.png")
    }

    @Test
    func materializesPNGClipboardImageAsTemporaryFile() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-clipboard-materializer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let pasteboard = NSPasteboard(name: .init("ssh-clipboard-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        pasteboard.setData(try tinyPNGData(), forType: .png)

        let materializer = ClipboardImageMaterializer(temporaryDirectory: scratchDir)
        let files = try materializer.materializeFiles(from: pasteboard)
        defer { materializer.cleanupTemporaryFiles(files) }

        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.isTemporary)
        #expect(file.url.lastPathComponent.hasPrefix("clipboard-"))
        #expect(file.url.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test
    func remoteClipboardWriterUsesSSHWithImageBackendScript() throws {
        let recorder = InvocationRecorder()
        let writer = RemoteClipboardWriter(runner: CommandRunner { executable, arguments, _ in
            recorder.append(executable: executable, arguments: arguments)
            return CommandResult(status: 0, stdout: "", stderr: "")
        })

        try writer.writeImagePaths(
            ["/tmp/cmux-drop-123.png"],
            session: RemoteSSHSession(destination: "example.com")
        )

        let invocations = recorder.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations[0].0 == "/usr/bin/ssh")
        #expect(invocations[0].1.contains("example.com"))
        let command = try #require(invocations[0].1.last)
        #expect(command.contains("wl-copy"))
        #expect(command.contains("xclip"))
        #expect(command.contains("/tmp/cmux-drop-123.png"))
    }

    @Test
    func remoteClipboardWriterCanUseRemoteHelper() throws {
        let recorder = InvocationRecorder()
        let writer = RemoteClipboardWriter(runner: CommandRunner { executable, arguments, _ in
            recorder.append(executable: executable, arguments: arguments)
            return CommandResult(status: 0, stdout: "", stderr: "")
        })

        try writer.writeImagePaths(
            ["/tmp/cmux-drop-123.png"],
            session: RemoteSSHSession(destination: "example.com"),
            remoteHelperPath: "~/.local/bin/ssh-clipboard-image-remote.py"
        )

        let command = try #require(recorder.snapshot().first?.1.last)
        #expect(command.contains("python3 \"$HOME/.local/bin/ssh-clipboard-image-remote.py\""))
        #expect(command.contains("write-image"))
        #expect(command.contains("--mime image/png"))
    }

    @Test
    func remoteHelperPathExpandsHomeOnRemoteShell() {
        #expect(RemoteClipboardWriter.remoteHelperCommandPath("~/.local/bin/helper.py") == "\"$HOME/.local/bin/helper.py\"")
        #expect(RemoteClipboardWriter.remoteHelperCommandPath("/opt/helper.py") == "/opt/helper.py")
    }

    @Test
    func remoteClipboardMimeTypeFollowsImageExtension() {
        #expect(RemoteClipboardWriter.mimeType(forRemotePath: "/tmp/a.png") == "image/png")
        #expect(RemoteClipboardWriter.mimeType(forRemotePath: "/tmp/a.jpg") == "image/jpeg")
        #expect(RemoteClipboardWriter.mimeType(forRemotePath: "/tmp/a.webp") == "image/webp")
    }

    private func tinyPNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [(String, [String])] = []

    func append(executable: String, arguments: [String]) {
        lock.lock()
        invocations.append((executable, arguments))
        lock.unlock()
    }

    func snapshot() -> [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}
