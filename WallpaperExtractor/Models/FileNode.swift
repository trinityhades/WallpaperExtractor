import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String           // full path as stable id
    let name: String         // last path component
    let path: String         // full relative path inside pkg
    let isDirectory: Bool
    let size: Int            // 0 for directories
    var children: [FileNode] // empty for files

    init(path: String, isDirectory: Bool, size: Int = 0, children: [FileNode] = []) {
        self.id = path
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }
}
