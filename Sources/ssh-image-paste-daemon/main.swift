import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SSHImagePasteCore

struct DaemonOptions {
    var interval: TimeInterval = 0.75
    var remoteHelperPath: String? = "~/.local/bin/ssh-clipboard-image-remote.py"
    var copyRemotePathToLocalClipboard = true
    var remoteClipboard = true
    var ttyInject = false
    var pasteIntercept = false
    var once = false
    var verbose = false
}

enum DaemonCLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

func parseOptions(_ arguments: [String]) throws -> DaemonOptions {
    var options = DaemonOptions()
    var index = 0

    func requireValue(for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw DaemonCLIError.usage("\(flag) requires a value.")
        }
        return arguments[index]
    }

    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--help", "-h":
            printUsageAndExit(0)
        case "--interval":
            let value = try requireValue(for: arg)
            guard let interval = TimeInterval(value), interval > 0 else {
                throw DaemonCLIError.usage("--interval requires a positive number.")
            }
            options.interval = interval
        case "--remote-helper":
            options.remoteHelperPath = try requireValue(for: arg)
        case "--no-remote-helper":
            options.remoteHelperPath = nil
        case "--no-local-path-clipboard":
            options.copyRemotePathToLocalClipboard = false
        case "--no-remote-clipboard":
            options.remoteClipboard = false
        case "--tty-inject":
            options.ttyInject = true
        case "--no-tty-inject":
            options.ttyInject = false
        case "--paste-intercept":
            options.pasteIntercept = true
        case "--no-paste-intercept":
            options.pasteIntercept = false
        case "--once":
            options.once = true
        case "--verbose":
            options.verbose = true
        default:
            throw DaemonCLIError.usage("Unknown option: \(arg)")
        }
        index += 1
    }

    return options
}

final class ClipboardSyncDaemon: @unchecked Sendable {
    private let options: DaemonOptions
    private let materializer = ClipboardImageMaterializer()
    private let uploader = RemoteUploader()
    private let writer = RemoteClipboardWriter()
    private let injector = TerminalPasteInjector()
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSyncedFingerprint: String?
    private var eventTap: CFMachPort?
    private var suppressNextCommandVPaste = false

    init(options: DaemonOptions) {
        self.options = options
    }

    func run() {
        if options.once {
            syncCurrentClipboard(reason: "once")
            return
        }

        log("watching clipboard every \(options.interval)s")
        if options.pasteIntercept {
            startPasteInterceptor()
        }
        Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.run()
    }

    private func poll() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        syncCurrentClipboard(reason: "change")
    }

    @discardableResult
    private func syncCurrentClipboard(reason: String) -> Bool {
        let files: [ClipboardMaterializedFile]
        do {
            files = try materializer.materializeFilesFromGeneralPasteboard()
        } catch ClipboardMaterializationError.noUsableClipboardImageOrFile {
            log("ignored non-image clipboard change")
            return false
        } catch {
            log("clipboard materialization failed: \(error.localizedDescription)")
            return false
        }
        defer { materializer.cleanupTemporaryFiles(files) }

        let fingerprint = clipboardFingerprint(files)
        guard fingerprint != lastSyncedFingerprint else {
            log("ignored duplicate clipboard payload")
            return false
        }

        let activeSessions = SSHSessionDetector.detectActiveInteractiveSSHSessions()
        guard !activeSessions.isEmpty else {
            log("no active ssh sessions for \(reason)")
            return false
        }

        let localURLs = files.map(\.url)
        let sharedRemotePaths = remotePaths(for: localURLs)
        var uploadedSessions: [(active: ActiveSSHSession, remotePaths: [String])] = []
        for active in activeSessions {
            do {
                let remotePaths = try uploader.upload(
                    localURLs,
                    to: active.session,
                    remotePaths: sharedRemotePaths
                )
                uploadedSessions.append((active: active, remotePaths: remotePaths))
                log("uploaded \(files.count) file(s) to \(active.session.destination) via \(active.tty)")
            } catch {
                log("sync failed for \(active.session.destination): \(error.localizedDescription)")
            }
        }

        guard !uploadedSessions.isEmpty else { return false }

        lastSyncedFingerprint = fingerprint
        if options.copyRemotePathToLocalClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                sharedRemotePaths.map(\.shellEscaped).joined(separator: " "),
                forType: .string
            )
            lastChangeCount = NSPasteboard.general.changeCount
            log("copied remote path(s) to local clipboard for Claude Code")
        }

        for uploaded in uploadedSessions {
            let active = uploaded.active
            let remotePaths = uploaded.remotePaths
            if options.ttyInject {
                do {
                    let insertedText = remotePaths.map(\.shellEscaped).joined(separator: " ")
                    try injector.injectBracketedPaste(insertedText, intoTTY: active.tty)
                    log("injected bracketed paste into \(active.tty) for \(active.session.destination)")
                } catch {
                    log("tty injection unavailable for \(active.tty): \(error.localizedDescription)")
                }
            }

            guard options.remoteClipboard else { continue }
            do {
                try writer.writeImagePaths(
                    remotePaths,
                    session: active.session,
                    remoteHelperPath: options.remoteHelperPath
                )
                log("wrote remote clipboard for \(active.session.destination)")
            } catch {
                log("remote clipboard unavailable for \(active.session.destination): \(error.localizedDescription)")
            }
        }

        return true
    }

    private func startPasteInterceptor() {
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                log("requesting Input Monitoring permission for paste intercept")
                _ = CGRequestListenEventAccess()
            }
            if !CGPreflightPostEventAccess() {
                log("requesting Accessibility permission for replaying Cmd-V")
                _ = CGRequestPostEventAccess()
            }
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: pasteEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("paste intercept unavailable; grant Accessibility/Input Monitoring if macOS prompts")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("paste intercept enabled for terminal apps")
    }

    fileprivate func handleKeyDownEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isCommandV(event) else {
            return Unmanaged.passUnretained(event)
        }

        if suppressNextCommandVPaste {
            suppressNextCommandVPaste = false
            return Unmanaged.passUnretained(event)
        }

        guard isFrontmostTerminalLikeApp() else {
            return Unmanaged.passUnretained(event)
        }

        guard ClipboardImageMaterializer.pasteboardMayContainImageOrFile(.general) else {
            return Unmanaged.passUnretained(event)
        }

        log("intercepted Cmd-V image paste in terminal app")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.syncCurrentClipboard(reason: "paste-intercept") {
                self.replayCommandV()
            }
        }
        return nil
    }

    private func replayCommandV() {
        suppressNextCommandVPaste = true
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            log("could not create replay Cmd-V event")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("replayed Cmd-V after path upload")
    }

    private func isCommandV(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 9 else { return false }
        let flags = event.flags
        return flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    private func isFrontmostTerminalLikeApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = app.bundleIdentifier ?? ""
        let knownTerminalBundleIDs: Set<String> = [
            "dev.warp.Warp-Stable",
            "dev.commandline.waveterm",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty"
        ]
        if knownTerminalBundleIDs.contains(bundleID) {
            return true
        }
        let name = app.localizedName?.lowercased() ?? ""
        return ["warp", "wave", "iterm", "terminal", "ghostty"].contains(name)
    }

    private func clipboardFingerprint(_ files: [ClipboardMaterializedFile]) -> String {
        files.map { file in
            let values = try? file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return [
                file.url.path,
                String(values?.fileSize ?? -1),
                String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    private func remotePaths(for fileURLs: [URL]) -> [String] {
        let salt = UUID().uuidString.lowercased()
        return fileURLs.enumerated().map { index, fileURL in
            let ext = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let suffix = ext.isEmpty ? "png" : ext
            let digest = digestPrefix(for: fileURL) ?? "\(salt)-\(index)"
            return "/tmp/ssh-image-paste-\(digest).\(suffix)"
        }
    }

    private func digestPrefix(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func log(_ message: String) {
        guard options.verbose else { return }
        let line = "[ssh-image-paste-daemon] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private func pasteEventCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown,
          let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let daemon = Unmanaged<ClipboardSyncDaemon>.fromOpaque(refcon).takeUnretainedValue()
    return daemon.handleKeyDownEvent(event)
}

func printUsageAndExit(_ code: Int32) -> Never {
    let text = """
    Usage:
      ssh-image-paste-daemon [options]

    Watches the local macOS clipboard. When it changes to an image/file payload,
    uploads it to every active interactive ssh session and writes the remote
    system clipboard through the remote helper or inline wl-copy/xclip fallback.

    Options:
      --interval SECONDS     Clipboard polling interval. Default: 0.75.
      --remote-helper PATH   Remote helper path. Default: ~/.local/bin/ssh-clipboard-image-remote.py.
      --no-remote-helper     Use inline remote wl-copy/xclip/osascript script.
      --no-local-path-clipboard
                              Do not replace local clipboard with uploaded remote path(s).
      --no-remote-clipboard  Only upload and local-copy paths; skip remote GUI clipboard writes.
      --tty-inject           Experimental: inject bracketed paste into detected ssh TTYs.
      --no-tty-inject        Disable experimental TTY injection. Default.
      --paste-intercept      Experimental: intercept Cmd-V in terminal apps, upload first,
                              then replay Cmd-V as text path paste.
      --no-paste-intercept   Disable Cmd-V interception. Default.
      --once                 Sync current clipboard once and exit.
      --verbose              Log sync activity to stderr.
      -h, --help             Show this help.
    """
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
    exit(code)
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let daemon = ClipboardSyncDaemon(options: options)
    daemon.run()
} catch let error as DaemonCLIError {
    fputs("error: \(error.localizedDescription)\n\n", stderr)
    printUsageAndExit(2)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
