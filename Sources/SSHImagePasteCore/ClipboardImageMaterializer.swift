import AppKit
import Foundation
import UniformTypeIdentifiers

public struct ClipboardMaterializedFile: Equatable {
    public var url: URL
    public var isTemporary: Bool
}

public enum ClipboardMaterializationError: Error, LocalizedError, Equatable {
    case noUsableClipboardImageOrFile
    case imageTooLarge(Int)
    case failedToWriteTemporaryFile

    public var errorDescription: String? {
        switch self {
        case .noUsableClipboardImageOrFile:
            return "Clipboard does not contain a file URL or decodable image."
        case .imageTooLarge(let byteCount):
            return "Clipboard image is too large: \(byteCount) bytes."
        case .failedToWriteTemporaryFile:
            return "Failed to write clipboard image to a temporary file."
        }
    }
}

public final class ClipboardImageMaterializer {
    public static let maxClipboardImageSize = 10 * 1024 * 1024

    private let temporaryDirectory: URL

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    public func materializeFilesFromGeneralPasteboard() throws -> [ClipboardMaterializedFile] {
        try materializeFiles(from: .general)
    }

    public static func pasteboardMayContainImageOrFile(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) {
            return true
        }
        if types.contains(.png) || types.contains(.tiff) {
            return true
        }
        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    public func materializeFiles(from pasteboard: NSPasteboard) throws -> [ClipboardMaterializedFile] {
        let fileURLs = fileURLs(from: pasteboard)
            .filter { isRegularFile($0) }
            .map { ClipboardMaterializedFile(url: $0, isTemporary: false) }
        if !fileURLs.isEmpty {
            return fileURLs
        }

        guard let representation = imageRepresentation(in: pasteboard) else {
            throw ClipboardMaterializationError.noUsableClipboardImageOrFile
        }
        guard representation.data.count <= Self.maxClipboardImageSize else {
            throw ClipboardMaterializationError.imageTooLarge(representation.data.count)
        }

        let fileURL = temporaryImageFileURL(fileExtension: representation.fileExtension)
        do {
            try representation.data.write(to: fileURL, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ClipboardMaterializationError.failedToWriteTemporaryFile
        }
        return [ClipboardMaterializedFile(url: fileURL, isTemporary: true)]
    }

    public func cleanupTemporaryFiles(_ files: [ClipboardMaterializedFile]) {
        for file in files where file.isTemporary {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var result: [URL] = []
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            if let url = object as? URL, url.isFileURL {
                result.append(url.standardizedFileURL)
            }
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL {
            result.append(url.standardizedFileURL)
        }

        var seen: Set<String> = []
        return result.filter { seen.insert($0.path).inserted }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.standardizedFileURL.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private func imageRepresentation(in pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            return normalizedPNGRepresentation(from: tiffData)
        }

        for type in pasteboard.types ?? [] {
            guard let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else {
                continue
            }
            if utType.conforms(to: .tiff) {
                return normalizedPNGRepresentation(from: data)
            }
            if let ext = utType.preferredFilenameExtension, !ext.isEmpty {
                return (data, ext.lowercased())
            }
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation else {
            return nil
        }
        return normalizedPNGRepresentation(from: tiffData)
    }

    private func normalizedPNGRepresentation(from data: Data) -> (data: Data, fileExtension: String)? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (pngData, "png")
    }

    private func temporaryImageFileURL(fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let sanitizedExtension = sanitizeExtension(fileExtension)
        return temporaryDirectory.appendingPathComponent(
            "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).\(sanitizedExtension)"
        )
    }

    private func sanitizeExtension(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        return allowed.contains(value) ? value : "png"
    }
}
