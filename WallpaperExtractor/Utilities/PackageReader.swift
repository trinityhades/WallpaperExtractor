import Foundation

struct PackageEntry {
    let name: String
    let offset: Int
    let size: Int
}

class PackageReader {
    private let data: Data
    private var position: Int = 0
    private var dataStart: Int = 0

    init(data: Data) {
        self.data = data
    }

    /// Reads the package header and returns entries.
    /// Format (as in C# RePKG):
    /// - magic: string prefixed with Int32 length (max ~32)
    /// - entryCount: Int32
    /// - for each entry:
    ///     - fullPath: string prefixed with Int32 length (max 255)
    ///     - offset: Int32 (relative to dataStart)
    ///     - length: Int32
    /// - body: concatenated entry bytes
    func readEntries() throws -> [PackageEntry] {
        position = 0

        // Read magic string (length-prefixed Int32)
        let magicLen = try readInt32()
        guard magicLen >= 0 && magicLen <= 32 else { throw ExtractionError.invalidFormat }
        let magic = try readString(length: Int(magicLen))
        // Accept any magic; format varies. We only validate bounds.
        _ = magic

        // Read entry count
        let entryCount = try readInt32()
        guard entryCount >= 0 && entryCount < 100_000 else { throw ExtractionError.invalidFormat }

        var entries: [PackageEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            let nameLen = try readInt32()
            guard nameLen > 0 && nameLen <= 255 else { throw ExtractionError.invalidFormat }
            let name = try readString(length: Int(nameLen))

            let off = try readInt32()
            let len = try readInt32()
            guard off >= 0 && len >= 0 else { throw ExtractionError.invalidFormat }

            entries.append(PackageEntry(name: name, offset: Int(off), size: Int(len)))
        }

        // Record where body starts; offsets are relative to this.
        dataStart = position
        return entries
    }

    func extractEntry(_ entry: PackageEntry) throws -> Data {
        // Compute absolute range using dataStart
        let start = dataStart + entry.offset
        let end = start + entry.size

        guard start >= 0, end >= start, end <= data.count else {
            throw ExtractionError.invalidFormat
        }

        return data.subdata(in: start..<end)
    }

    // Note: call readEntries() again if you need to refresh entries

    // MARK: - Binary reading

    private func readInt32() throws -> Int32 {
        guard position + 4 <= data.count else { throw ExtractionError.invalidFormat }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: Int32.self) }
        position += 4
        return v
    }

    private func readString(length: Int) throws -> String {
        guard length >= 0, position + length <= data.count else { throw ExtractionError.invalidFormat }
        let sub = data.subdata(in: position..<position+length)
        position += length
        // Strings written by C# are not null-terminated and may contain relative paths.
        guard let s = String(data: sub, encoding: .utf8) else { throw ExtractionError.invalidFormat }
        return s
    }
}
