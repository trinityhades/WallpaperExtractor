import Foundation

extension URL {
    /// Safely appends a possibly nested relative path like "dir/sub/file.txt"
    /// by splitting on '/' and appending path components one by one.
    /// Marks all intermediate components as directories for correct path creation.
    func appendingPathComponentsSafe(_ relativePath: String) -> URL {
        let parts = relativePath.split(separator: "/").map(String.init)
        var result = self
        for (idx, part) in parts.enumerated() {
            let isDir = idx < parts.count - 1
            result = result.appendingPathComponent(part, isDirectory: isDir)
        }
        return result
    }
}
