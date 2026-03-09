import AppKit
import Foundation

struct ProjectMetadata: Decodable {
    let preview: String?
    let tags: [String]?
    let title: String?
}

struct WorkshopItem: Identifiable {
    let id = UUID()
    let folderURL: URL
    let metadata: ProjectMetadata
    let previewImage: NSImage?
    let previewURL: URL?
    let pkgFiles: [URL]
    let downloadDate: Date?
    
    var isAnimatedPreview: Bool {
        guard let url = previewURL else { return false }
        return url.pathExtension.lowercased() == "gif"
    }
}

extension SteamCMDManager {
    func scanDownloadedWorkshopItems() -> [WorkshopItem] {
        // Workshop Engine app id folder
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Steam")
            .appendingPathComponent("steamapps")
            .appendingPathComponent("workshop")
            .appendingPathComponent("content")
            .appendingPathComponent(workshopAppID)
        var results: [WorkshopItem] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return [] }
        guard
            let dirs = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        for dir in dirs {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                continue
            }
            let projectJSON = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectJSON) else { continue }
            guard let meta = try? JSONDecoder().decode(ProjectMetadata.self, from: data) else {
                continue
            }
            // Load preview image if present
            var previewImage: NSImage? = nil
            var previewURL: URL? = nil
            if let previewName = meta.preview {
                let url = dir.appendingPathComponent(previewName)
                previewURL = url
                if let imgData = try? Data(contentsOf: url), let img = NSImage(data: imgData)
                {
                    previewImage = img
                }
            }
            // Find PKG files directly under folder (non-recursive)
            var pkgFiles: [URL] = []
            if let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            {
                for file in items where file.pathExtension.lowercased() == "pkg" {
                    pkgFiles.append(file)
                }
            }
            // Determine download/modified date for sorting
            var downloadDate: Date? = nil
            if let attrs = try? fm.attributesOfItem(atPath: dir.path) {
                downloadDate =
                    (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date)
            }
            results.append(
                WorkshopItem(
                    folderURL: dir, metadata: meta, previewImage: previewImage, previewURL: previewURL, pkgFiles: pkgFiles,
                    downloadDate: downloadDate))
        }
        return results
    }

    func deleteWorkshopItem(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        // Try to move to Trash first for safety
        if let trashURL = try? fm.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
        {
            let dest = trashURL.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: dest)
                return
            } catch {
                // Fallback to removeItem
            }
        }
        try fm.removeItem(at: url)
    }
}
