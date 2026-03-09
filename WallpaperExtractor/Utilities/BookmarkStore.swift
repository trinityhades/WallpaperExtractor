import Foundation

enum BookmarkStore {
    private static let defaults = UserDefaults.standard

    static func save(url: URL, forKey key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: key)
        } catch {
            print("BookmarkStore.save error: \(error)")
        }
    }

    static func resolve(forKey key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            if stale {
                // Refresh bookmark
                do { try refresh(url: url, forKey: key) } catch {
                    print("Bookmark refresh failed: \(error)")
                }
            }
            return url
        } catch {
            print("BookmarkStore.resolve error: \(error)")
            return nil
        }
    }

    static func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    private static func refresh(url: URL, forKey key: String) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }
}
