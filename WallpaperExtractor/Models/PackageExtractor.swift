import Foundation
import AppKit
import Combine
import ImageIO

class PackageExtractor: ObservableObject {
    @Published var extractedImages: [ExtractedImage] = []
    @Published var isExtracting = false
    // Whether a package has been loaded (even if it has no previewable images)
    @Published var hasLoadedPackage: Bool = false
    // Tree of files/folders inside the package for UI listing
    @Published var fileTree: [FileNode] = []
    private var lastSourceURL: URL?
    private var lastPackageData: Data?
    private var lastEntries: [PackageEntry] = []
    private var entriesByPath: [String: PackageEntry] = [:]
    // Expose export availability and basic counts to the UI
    var canExport: Bool { lastPackageData != nil && !lastEntries.isEmpty }
    var entriesCount: Int { lastEntries.count }

    func extractPackage(from url: URL) async throws {
        isExtracting = true
        defer { isExtracting = false }

        guard url.startAccessingSecurityScopedResource() else {
            throw ExtractionError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)
        let reader = PackageReader(data: data)
        self.lastSourceURL = url
        self.lastPackageData = data

        extractedImages.removeAll()

        let entries = try reader.readEntries()
        self.lastEntries = entries
        self.entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        self.fileTree = buildFileTree(from: entries)
        self.hasLoadedPackage = true

        for entry in entries {
            let lower = entry.name.lowercased()
            if lower.hasSuffix(".tex") {
                do {
                    let texData = try reader.extractEntry(entry)
                    if let image = try TexDecoder.decode(texData) {
                        let imageName = (entry.name as NSString).lastPathComponent
                        extractedImages.append(ExtractedImage(image: image, name: imageName))
                    }
                } catch {
                    print("Failed to extract \(entry.name): \(error)")
                }
            } else {
                // Try preview non-tex image files directly
                do {
                    let bytes = try reader.extractEntry(entry)
                    if let image = decodeAnyImage(from: bytes) {
                        let imageName = (entry.name as NSString).lastPathComponent
                        extractedImages.append(ExtractedImage(image: image, name: imageName))
                    }
                } catch {
                    // ignore preview failure
                }
            }
        }

        // Do not throw just because there are no previewable images.
        // Many packages contain videos or other assets; users should still be able to Export All.
        // Leave extractedImages empty and let the UI present Export options.
    }

    // MARK: - Data access & previews

    func dataFor(path: String) throws -> Data {
        guard let data = lastPackageData else { throw ExtractionError.invalidFormat }
        let reader = PackageReader(data: data)
        // Note: readEntries establishes dataStart; reuse cached lastEntries for speed
        _ = try? reader.readEntries()
        guard let entry = entriesByPath[path] else { throw ExtractionError.invalidFormat }
        return try reader.extractEntry(entry)
    }

    func previewImage(for path: String) -> NSImage? {
        let lower = path.lowercased()
        do {
            let bytes = try dataFor(path: path)
            if lower.hasSuffix(".tex") {
                if let image = try TexDecoder.decode(bytes) { return image }
                return nil
            } else {
                return decodeAnyImage(from: bytes)
            }
        } catch { return nil }
    }

    private func buildFileTree(from entries: [PackageEntry]) -> [FileNode] {
        final class TNode {
            var name: String
            var children: [String: TNode] = [:]
            var isDirectory: Bool = true
            var size: Int = 0
            init(_ name: String) { self.name = name }
        }

        let root = TNode("")

        func insert(path: String, size: Int) {
            let parts = path.split(separator: "/").map(String.init)
            var cursor = root
            for (idx, part) in parts.enumerated() {
                if cursor.children[part] == nil { cursor.children[part] = TNode(part) }
                cursor = cursor.children[part]!
                if idx == parts.count - 1 {
                    // file node
                    cursor.isDirectory = false
                    cursor.size = size
                }
            }
        }

        for e in entries { insert(path: e.name, size: e.size) }

        func toNodes(prefix: String, node: TNode) -> [FileNode] {
            // Convert children into FileNodes, sorted with folders first, then files by name
            var folders: [FileNode] = []
            var files: [FileNode] = []
            for (name, child) in node.children {
                let childPath = prefix.isEmpty ? name : (prefix + "/" + name)
                if child.isDirectory {
                    let grand = toNodes(prefix: childPath, node: child)
                    folders.append(FileNode(path: childPath, isDirectory: true, size: 0, children: grand))
                } else {
                    files.append(FileNode(path: childPath, isDirectory: false, size: child.size, children: []))
                }
            }
            folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return folders + files
        }

        return toNodes(prefix: "", node: root)
    }

    // Export all entries to a chosen folder. TEX -> PNG (fallback to raw), others raw
    func exportAll(to destinationFolder: URL) throws {
        var startedAccess = false
        if destinationFolder.startAccessingSecurityScopedResource() {
            startedAccess = true
        }
        defer { if startedAccess { destinationFolder.stopAccessingSecurityScopedResource() } }
        guard let data = lastPackageData else { throw ExtractionError.invalidFormat }
        let reader = PackageReader(data: data)
        let entries = (try? reader.readEntries()) ?? self.lastEntries

        // Build a set of directory-like paths from entry parents to avoid file/dir name collisions
        var directoryPaths = Set<String>()
        for e in entries {
            let parts = e.name.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for i in 1..<parts.count {
                    let dir = parts[0..<i].joined(separator: "/")
                    directoryPaths.insert(dir)
                }
            }
        }

        for entry in entries {
            let lower = entry.name.lowercased()
            let bytes = try reader.extractEntry(entry)
            // If this entry is effectively a directory marker (prefix of other files), skip writing as a file
            if directoryPaths.contains(entry.name) {
                // Ensure the directory exists
                let dirURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                continue
            }

            if lower.hasSuffix(".tex") {
                // Check if it's actually an MP4 video file
                // MP4 signature "ftyp" can appear after TEX header (usually within first 200 bytes)
                var mp4Offset: Int?
                let searchLimit = min(200, bytes.count - 4)
                for offset in 0..<searchLimit {
                    if bytes[offset] == 0x66 && bytes[offset+1] == 0x74 &&
                       bytes[offset+2] == 0x79 && bytes[offset+3] == 0x70 {
                        // MP4 files start with a size box, ftyp is usually at offset 4
                        // So the actual MP4 start is typically 4 bytes before ftyp
                        mp4Offset = max(0, offset - 4)
                        break
                    }
                }

                if let mp4Start = mp4Offset {
                    // Extract and write only the MP4 data (skip TEX header)
                    let mp4Data = bytes.subdata(in: mp4Start..<bytes.count)
                    let mp4Name = ((entry.name as NSString).deletingPathExtension) + ".mp4"
                    let outURL = destinationFolder.appendingPathComponentsSafe(mp4Name)
                    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try mp4Data.write(to: outURL)
                    print("🎬 Extracted MP4 from \(entry.name) -> \(mp4Name) (offset: \(mp4Start))")
                    continue
                }

                // Try to decode TEX -> PNG; if decoding fails, write raw .tex to avoid losing content
                do {
                    if let image = try TexDecoder.decode(bytes) {
                        let pngName = ((entry.name as NSString).deletingPathExtension) + ".png"
                        let outURL = destinationFolder.appendingPathComponentsSafe(pngName)
                        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                        // Convert to PNG data
                        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            let newRep = NSBitmapImageRep(cgImage: cgImage)
                            newRep.size = image.size
                            if let pngData = newRep.representation(using: .png, properties: [:]) {
                                try pngData.write(to: outURL)
                                print("✅ Converted \(entry.name) -> \(pngName)")
                            } else {
                                // Fallback: write raw TEX
                                print("⚠️ PNG encoding failed for \(entry.name), writing raw .tex")
                                let outURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try bytes.write(to: outURL)
                            }
                        } else {
                            // Fallback: write raw TEX
                            print("⚠️ CGImage creation failed for \(entry.name), writing raw .tex")
                            let outURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try bytes.write(to: outURL)
                        }
                    } else {
                        // No image decoded -> write raw TEX
                        print("⚠️ TexDecoder failed for \(entry.name), writing raw .tex")
                        let outURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try bytes.write(to: outURL)
                    }
                } catch {
                    // Decoding failed -> write raw TEX
                    print("❌ Exception decoding \(entry.name): \(error), writing raw .tex")
                    let outURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: outURL)
                }
            } else {
                // Write raw bytes preserving relative path
                let outURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: outURL)
            }
        }
    }

    // Try to decode arbitrary image bytes using NSImage or ImageIO (CGImageSource)
    private func decodeAnyImage(from data: Data) -> NSImage? {
        if let nsImage = NSImage(data: data) { return nsImage }
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil),
              CGImageSourceGetCount(src) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

enum ExtractionError: LocalizedError {
    case accessDenied
    case invalidFormat
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Unable to access the selected file"
        case .invalidFormat:
            return "Invalid PKG file format"
        case .decompressionFailed:
            return "Failed to decompress texture data"
        }
    }
}
