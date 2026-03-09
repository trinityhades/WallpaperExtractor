import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

class PackageExtractor: ObservableObject {
    enum PreviewContent {
        case image(NSImage)
        case video(URL)
        case unsupported
    }

    @Published var extractedImages: [ExtractedImage] = []
    @Published var isExtracting = false
    @Published var extractionProgress: Double = 0.0  // 0.0 - 1.0
    @Published var extractionMessage: String = ""  // human-readable status
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

    // Remove stale temporary raw exported files created for drag-and-drop.
    func cleanupTemporaryRawDirectory() {
        cleanupTemporaryDirectory(named: "WallpaperExtractorRaw")
        cleanupTemporaryDirectory(named: "WallpaperExtractorPreview")
    }

    private func cleanupTemporaryDirectory(named directoryName: String) {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            directoryName, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: tempRoot.path) {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: tempRoot, includingPropertiesForKeys: nil, options: [])
                for url in contents {
                    try? FileManager.default.removeItem(at: url)
                }
                // Attempt to remove directory itself (okay if it fails because files might be in use)
                try? FileManager.default.removeItem(at: tempRoot)
            }
        } catch {
            print("Temp cleanup failed: \(error)")
        }
    }

    struct ExportOptions {
        var includeImages: Bool = true
        var includeVideos: Bool = true
        var includeOther: Bool = true
        var flattenFolders: Bool = false
        var trinityPreferred: Bool = false
        var exportMipmaps: Bool = false
        var nonPremultipliedAlpha: Bool = false
        var useLinearColorSpace: Bool = false
    }

    func extractPackage(from url: URL) async throws {
        isExtracting = true
        extractionProgress = 0
        extractionMessage = "Reading package entries…"
        defer {
            isExtracting = false
            extractionMessage = extractionProgress >= 1 ? "Finished" : extractionMessage
        }

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

        let total = max(1, entries.count)
        var processed = 0
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
            processed += 1
            if processed % 10 == 0 || processed == total {  // reduce UI churn
                let percent = Double(processed) / Double(total)
                extractionProgress = percent
                extractionMessage = "Processing \(processed)/\(total) files…"
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
        switch previewContent(for: path) {
        case .image(let image):
            return image
        case .video, .unsupported:
            return nil
        }
    }

    func previewContent(for path: String) -> PreviewContent {
        let lower = path.lowercased()
        do {
            let bytes = try dataFor(path: path)
            if lower.hasSuffix(".tex") {
                if let embeddedVideoData = extractEmbeddedMP4(from: bytes) {
                    let videoURL = try temporaryPreviewVideoURL(
                        for: path, videoData: embeddedVideoData, fileExtension: "mp4")
                    return .video(videoURL)
                }
                if let image = try TexDecoder.decode(bytes) {
                    return .image(image)
                }
                return .unsupported
            }
            if Self.isVideoPath(lower) {
                let pathExtension = (path as NSString).pathExtension
                let videoURL = try temporaryPreviewVideoURL(
                    for: path, videoData: bytes,
                    fileExtension: pathExtension.isEmpty ? "mp4" : pathExtension)
                return .video(videoURL)
            }
            if let image = decodeAnyImage(from: bytes) {
                return .image(image)
            }
            return .unsupported
        } catch {
            return .unsupported
        }
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
                    folders.append(
                        FileNode(path: childPath, isDirectory: true, size: 0, children: grand))
                } else {
                    files.append(
                        FileNode(
                            path: childPath, isDirectory: false, size: child.size, children: []))
                }
            }
            folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return folders + files
        }

        return toNodes(prefix: "", node: root)
    }

    // Export all entries to a chosen folder. TEX -> PNG/MP4 (fallback to raw), others raw
    func exportAll(to destinationFolder: URL) throws {
        try export(to: destinationFolder, options: ExportOptions())
    }

    // Export respecting options (images/videos/other)
    func export(to destinationFolder: URL, options: ExportOptions) throws {
        var startedAccess = false
        if destinationFolder.startAccessingSecurityScopedResource() {
            startedAccess = true
        }
        defer { if startedAccess { destinationFolder.stopAccessingSecurityScopedResource() } }
        guard let data = lastPackageData else { throw ExtractionError.invalidFormat }
        let reader = PackageReader(data: data)
        let entries = (try? reader.readEntries()) ?? self.lastEntries

        extractionProgress = 0
        extractionMessage = "Exporting…"
        let total = max(1, entries.count)
        var processed = 0

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
                if !options.flattenFolders {
                    let dirURL = destinationFolder.appendingPathComponentsSafe(entry.name)
                    try FileManager.default.createDirectory(
                        at: dirURL, withIntermediateDirectories: true)
                }
                continue
            }

            if lower.hasSuffix(".tex") {
                // Detect embedded MP4 inside TEX (look for 'ftyp')
                var mp4Offset: Int?
                if bytes.count >= 8 {  // minimal length for search
                    let limit = min(200, max(0, bytes.count - 4))
                    for offset in 0..<limit where bytes[offset] == 0x66 {  // 'f'
                        if bytes[offset + 1] == 0x74 && bytes[offset + 2] == 0x79
                            && bytes[offset + 3] == 0x70
                        {
                            mp4Offset = max(0, offset - 4)  // rewind typical header size box
                            break
                        }
                    }
                }
                if let start = mp4Offset {
                    guard options.includeVideos else { continue }
                    let mp4Data = bytes.subdata(in: start..<bytes.count)
                    let mp4NameRaw = ((entry.name as NSString).deletingPathExtension) + ".mp4"
                    let mp4Name =
                        options.flattenFolders
                        ? (mp4NameRaw as NSString).lastPathComponent : mp4NameRaw
                    let outURL = uniqueOutputURL(
                        baseName: mp4Name, destinationFolder: destinationFolder,
                        flatten: options.flattenFolders)
                    if !options.flattenFolders {
                        try FileManager.default.createDirectory(
                            at: outURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                    }
                    try mp4Data.write(to: outURL)
                    print("🎬 Extracted MP4 from \(entry.name) -> \(mp4Name) (offset: \(start))")
                    continue
                }

                // TEX -> PNG (optionally all mipmaps) (fallback raw TEX)
                do {
                    if !options.includeImages {  // user doesn't want images; optionally write raw as other
                        if options.includeOther {
                            let rawName =
                                options.flattenFolders
                                ? ((entry.name as NSString).lastPathComponent) : entry.name
                            let rawURL = uniqueOutputURL(
                                baseName: rawName, destinationFolder: destinationFolder,
                                flatten: options.flattenFolders)
                            if !options.flattenFolders {
                                try FileManager.default.createDirectory(
                                    at: rawURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
                            }
                            try bytes.write(to: rawURL)
                        }
                        continue
                    }

                    let colorSpace =
                        options.useLinearColorSpace
                        ? (CGColorSpace(name: CGColorSpace.linearSRGB)
                            ?? CGColorSpaceCreateDeviceRGB()) : CGColorSpaceCreateDeviceRGB()
                    let texOptions = TexDecoder.Options(
                        premultiplyAlpha: !options.nonPremultipliedAlpha, colorSpace: colorSpace)

                    if options.exportMipmaps {
                        let images = try TexDecoder.decodeAllMipmaps(bytes, options: texOptions)
                        guard !images.isEmpty else {
                            // fallback raw
                            if options.includeOther {
                                let rawName =
                                    options.flattenFolders
                                    ? ((entry.name as NSString).lastPathComponent) : entry.name
                                let rawURL = uniqueOutputURL(
                                    baseName: rawName, destinationFolder: destinationFolder,
                                    flatten: options.flattenFolders)
                                if !options.flattenFolders {
                                    try FileManager.default.createDirectory(
                                        at: rawURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                                }
                                try bytes.write(to: rawURL)
                            }
                            continue
                        }
                        for (idx, image) in images.enumerated() {
                            let suffix = idx == 0 ? "" : "-mip\(idx)"
                            let pngNameRaw =
                                ((entry.name as NSString).deletingPathExtension) + suffix + ".png"
                            let baseName: String
                            if options.trinityPreferred,
                                let rel = preferredImageRelativePath(
                                    for: entry.name,
                                    outputFileName: (pngNameRaw as NSString).lastPathComponent)
                            {
                                baseName = rel
                            } else {
                                baseName =
                                    options.flattenFolders
                                    ? ((pngNameRaw as NSString).lastPathComponent) : pngNameRaw
                            }
                            let outURL = uniqueOutputURL(
                                baseName: baseName, destinationFolder: destinationFolder,
                                flatten: options.flattenFolders && !options.trinityPreferred)
                            if !(options.flattenFolders && !options.trinityPreferred) {
                                try FileManager.default.createDirectory(
                                    at: outURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
                            }
                            if let cgImage = image.cgImage(
                                forProposedRect: nil, context: nil, hints: nil)
                            {
                                let rep = NSBitmapImageRep(cgImage: cgImage)
                                rep.size = image.size
                                if let pngData = rep.representation(using: .png, properties: [:]) {
                                    try pngData.write(to: outURL)
                                    print("✅ Converted TEX mip\(idx) \(entry.name) -> \(baseName)")
                                } else {
                                    print("⚠️ PNG encoding failed for mip \(idx) of \(entry.name)")
                                }
                            } else {
                                print("⚠️ CGImage creation failed for mip \(idx) of \(entry.name)")
                            }
                        }
                    } else {
                        guard let image = try TexDecoder.decode(bytes, options: texOptions) else {
                            if options.includeOther {  // write raw TEX
                                let rawName =
                                    options.flattenFolders
                                    ? ((entry.name as NSString).lastPathComponent) : entry.name
                                let outURL = uniqueOutputURL(
                                    baseName: rawName, destinationFolder: destinationFolder,
                                    flatten: options.flattenFolders)
                                if !options.flattenFolders {
                                    try FileManager.default.createDirectory(
                                        at: outURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                                }
                                try bytes.write(to: outURL)
                            }
                            continue
                        }
                        let pngNameRaw = ((entry.name as NSString).deletingPathExtension) + ".png"
                        let baseName: String
                        if options.trinityPreferred,
                            let rel = preferredImageRelativePath(
                                for: entry.name,
                                outputFileName: (pngNameRaw as NSString).lastPathComponent)
                        {
                            baseName = rel
                        } else {
                            baseName =
                                options.flattenFolders
                                ? ((pngNameRaw as NSString).lastPathComponent) : pngNameRaw
                        }
                        let outURL = uniqueOutputURL(
                            baseName: baseName, destinationFolder: destinationFolder,
                            flatten: options.flattenFolders && !options.trinityPreferred)
                        if !(options.flattenFolders && !options.trinityPreferred) {
                            try FileManager.default.createDirectory(
                                at: outURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                        }
                        if let cgImage = image.cgImage(
                            forProposedRect: nil, context: nil, hints: nil)
                        {
                            let rep = NSBitmapImageRep(cgImage: cgImage)
                            rep.size = image.size
                            if let pngData = rep.representation(using: .png, properties: [:]) {
                                try pngData.write(to: outURL)
                                print("✅ Converted TEX \(entry.name) -> \(baseName)")
                            } else {
                                print("⚠️ PNG encoding failed for \(entry.name), writing raw .tex")
                                if options.includeOther {
                                    let rawName =
                                        options.flattenFolders
                                        ? ((entry.name as NSString).lastPathComponent) : entry.name
                                    let rawURL = uniqueOutputURL(
                                        baseName: rawName, destinationFolder: destinationFolder,
                                        flatten: options.flattenFolders)
                                    if !options.flattenFolders {
                                        try FileManager.default.createDirectory(
                                            at: rawURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                                    }
                                    try bytes.write(to: rawURL)
                                }
                            }
                        } else {
                            print("⚠️ CGImage creation failed for \(entry.name), writing raw .tex")
                            if options.includeOther {
                                let rawName =
                                    options.flattenFolders
                                    ? ((entry.name as NSString).lastPathComponent) : entry.name
                                let rawURL = uniqueOutputURL(
                                    baseName: rawName, destinationFolder: destinationFolder,
                                    flatten: options.flattenFolders)
                                if !options.flattenFolders {
                                    try FileManager.default.createDirectory(
                                        at: rawURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                                }
                                try bytes.write(to: rawURL)
                            }
                        }
                    }
                } catch {
                    print("❌ Exception decoding TEX \(entry.name): \(error)")
                    if options.includeOther {
                        let rawName =
                            options.flattenFolders
                            ? ((entry.name as NSString).lastPathComponent) : entry.name
                        let rawURL = uniqueOutputURL(
                            baseName: rawName, destinationFolder: destinationFolder,
                            flatten: options.flattenFolders)
                        if !options.flattenFolders {
                            try FileManager.default.createDirectory(
                                at: rawURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                        }
                        try bytes.write(to: rawURL)
                    }
                }
            } else {
                // Decide type by extension
                let pathLower = lower
                let isImage = PackageExtractor.isImagePath(pathLower)
                let isVideo = PackageExtractor.isVideoPath(pathLower)

                if (isImage && options.includeImages) || (isVideo && options.includeVideos)
                    || (!isImage && !isVideo && options.includeOther)
                {
                    if isImage, options.trinityPreferred,
                        let rel = preferredImageRelativePath(
                            for: entry.name,
                            outputFileName: ((entry.name as NSString).lastPathComponent))
                    {
                        let outURL = uniqueOutputURL(
                            baseName: rel, destinationFolder: destinationFolder, flatten: false)
                        try FileManager.default.createDirectory(
                            at: outURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try bytes.write(to: outURL)
                    } else {
                        let rawName =
                            options.flattenFolders
                            ? ((entry.name as NSString).lastPathComponent) : entry.name
                        let outURL = uniqueOutputURL(
                            baseName: rawName, destinationFolder: destinationFolder,
                            flatten: options.flattenFolders)
                        if !options.flattenFolders {
                            try FileManager.default.createDirectory(
                                at: outURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                        }
                        try bytes.write(to: outURL)
                    }
                }
            }
            processed += 1
            if processed % 25 == 0 || processed == total {  // less frequent updates for export
                extractionProgress = Double(processed) / Double(total)
                extractionMessage = "Exported \(processed)/\(total)…"
            }
        }

        // Include external media files located alongside the .pkg (non-recursive)
        if let pkgURL = lastSourceURL {
            let parentDir = pkgURL.deletingLastPathComponent()
            var parentAccess = false
            if parentDir.startAccessingSecurityScopedResource() { parentAccess = true }
            defer { if parentAccess { parentDir.stopAccessingSecurityScopedResource() } }
            do {
                let items = try FileManager.default.contentsOfDirectory(
                    at: parentDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                for file in items {
                    // Skip the package itself and directories
                    if file == pkgURL { continue }
                    var isDir: ObjCBool = false
                    if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
                        || isDir.boolValue
                    {
                        continue
                    }
                    let lowerName = file.lastPathComponent.lowercased()
                    let isImage = PackageExtractor.isImagePath(lowerName)
                    let isVideo = PackageExtractor.isVideoPath(lowerName)
                    if (isImage && options.includeImages) || (isVideo && options.includeVideos) {
                        let baseName = file.lastPathComponent
                        let outURL = uniqueOutputURL(
                            baseName: baseName, destinationFolder: destinationFolder, flatten: true)
                        if let data = try? Data(contentsOf: file) {
                            try data.write(to: outURL)
                            print(
                                "📎 Copied external media \(file.lastPathComponent) -> \(outURL.lastPathComponent)"
                            )
                        }
                    }
                }
            } catch {
                print("External media scan failed: \(error)")
            }
        }
        extractionProgress = 1.0
        extractionMessage = "Export complete"
    }

    // Try to decode arbitrary image bytes using NSImage or ImageIO (CGImageSource)
    private func decodeAnyImage(from data: Data) -> NSImage? {
        if let nsImage = NSImage(data: data) { return nsImage }
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil),
            CGImageSourceGetCount(src) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private static func isImagePath(_ lowercasedPath: String) -> Bool {
        return lowercasedPath.hasSuffix(".png") || lowercasedPath.hasSuffix(".jpg")
            || lowercasedPath.hasSuffix(".jpeg") || lowercasedPath.hasSuffix(".gif")
            || lowercasedPath.hasSuffix(".tiff") || lowercasedPath.hasSuffix(".bmp")
            || lowercasedPath.hasSuffix(".heic") || lowercasedPath.hasSuffix(".webp")
    }

    private static func isVideoPath(_ lowercasedPath: String) -> Bool {
        return lowercasedPath.hasSuffix(".mp4") || lowercasedPath.hasSuffix(".mov")
            || lowercasedPath.hasSuffix(".m4v") || lowercasedPath.hasSuffix(".avi")
            || lowercasedPath.hasSuffix(".webm")
    }

    private func extractEmbeddedMP4(from bytes: Data) -> Data? {
        guard bytes.count >= 8 else { return nil }
        let searchLimit = min(200, max(0, bytes.count - 4))
        for offset in 0..<searchLimit where bytes[offset] == 0x66 {
            if bytes[offset + 1] == 0x74 && bytes[offset + 2] == 0x79
                && bytes[offset + 3] == 0x70
            {
                let start = max(0, offset - 4)
                return bytes.subdata(in: start..<bytes.count)
            }
        }
        return nil
    }

    private func temporaryPreviewVideoURL(for path: String, videoData: Data, fileExtension: String)
        throws -> URL
    {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WallpaperExtractorPreview", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let originalName = (path as NSString).deletingPathExtension
        let sanitizedName =
            originalName
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
        let targetURL = tempRoot.appendingPathComponent(sanitizedName).appendingPathExtension(
            fileExtension)

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try videoData.write(to: targetURL, options: .atomic)
        }

        return targetURL
    }

    private func uniqueOutputURL(baseName: String, destinationFolder: URL, flatten: Bool) -> URL {
        if !flatten { return destinationFolder.appendingPathComponentsSafe(baseName) }
        var candidate = destinationFolder.appendingPathComponent(baseName)
        let ext = (baseName as NSString).pathExtension
        let stem = (baseName as NSString).deletingPathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = destinationFolder.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    // Provide a temporary raw file URL (no conversion) for drag-and-drop out of the app.
    // Writes the original bytes exactly as stored in the package.
    func temporaryRawFileURL(for path: String) throws -> URL {
        let data = try dataFor(path: path)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WallpaperExtractorRaw", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        // Avoid collisions by appending a short UUID if already exists
        var target = tempRoot.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            let uuidFrag = UUID().uuidString.prefix(8)
            let ext = (fileName as NSString).pathExtension
            let stem = (fileName as NSString).deletingPathExtension
            let newName = ext.isEmpty ? "\(stem)-\(uuidFrag)" : "\(stem)-\(uuidFrag).\(ext)"
            target = tempRoot.appendingPathComponent(String(newName))
        }
        try data.write(to: target)
        return target
    }

    // Map original image paths into preferred folder structure when trinityPreferred is enabled.
    // Precedence: effects/masks/models/xray override materials even if nested under materials.
    private func preferredImageRelativePath(for originalPath: String, outputFileName: String)
        -> String?
    {
        let parts = originalPath.split(separator: "/").map { String($0) }
        let lower = parts.map { $0.lowercased() }

        // Find earliest occurrence of any category to unify into a single top-level folder
        let categories: [(token: String, folder: String)] = [
            ("effects", "Effects"),
            ("masks", "Masks"),
            ("models", "Models"),
            ("xray", "Xray"),
        ]
        var chosen: (idx: Int, folder: String)? = nil
        for (token, folder) in categories {
            if let idx = lower.firstIndex(of: token) {
                if let c = chosen {
                    if idx < c.idx { chosen = (idx, folder) }
                } else {
                    chosen = (idx, folder)
                }
            }
        }
        if let c = chosen {
            let suffix = parts.dropFirst(c.idx + 1)
            let dirComponents = Array(suffix.dropLast())
            let sub = dirComponents.joined(separator: "/")
            return sub.isEmpty
                ? [c.folder, outputFileName].joined(separator: "/")
                : [c.folder, sub, outputFileName].joined(separator: "/")
        }

        // Only route to Main Images if there is a materials component and no higher-precedence category
        if lower.contains("materials") {
            return ["Main Images", outputFileName].joined(separator: "/")
        }
        return nil
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
