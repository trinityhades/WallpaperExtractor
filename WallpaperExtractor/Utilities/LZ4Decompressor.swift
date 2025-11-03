import Foundation
import Compression

class LZ4Decompressor {
    static func decompress(_ compressedData: Data) throws -> Data {
        // Read uncompressed size from first 4 bytes
        let uncompressedSize = compressedData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }

        let compressedBytes = compressedData.dropFirst(4)

        var decompressedData = Data(count: Int(uncompressedSize))

        let decompressedSize = decompressedData.withUnsafeMutableBytes { destBuffer in
            compressedBytes.withUnsafeBytes { srcBuffer in
                compression_decode_buffer(
                    destBuffer.baseAddress!,
                    Int(uncompressedSize),
                    srcBuffer.baseAddress!,
                    srcBuffer.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        guard decompressedSize > 0 else {
            throw ExtractionError.decompressionFailed
        }

        return decompressedData
    }

    static func decompress(_ compressedData: Data, outputSize: Int) throws -> Data {
        guard outputSize > 0 && outputSize < 512 * 1024 * 1024 else {
            throw ExtractionError.decompressionFailed
        }

        func tryDecode(_ data: Data, algo: compression_algorithm) -> Data? {
            var out = Data(count: outputSize)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.baseAddress!,
                        outputSize,
                        src.baseAddress!,
                        src.count,
                        nil,
                        algo
                    )
                }
            }
            if written == outputSize { return out }
            return nil
        }

        // Try raw first (typical for RePKG TEX mipmaps), then framed, then drop 4-byte header fallback.
        if let out = tryDecode(compressedData, algo: COMPRESSION_LZ4_RAW) { return out }
        if let out = tryDecode(compressedData, algo: COMPRESSION_LZ4) { return out }
        if compressedData.count > 4 {
            let dropped = compressedData.dropFirst(4)
            if let out = tryDecode(dropped, algo: COMPRESSION_LZ4_RAW) { return out }
            if let out = tryDecode(dropped, algo: COMPRESSION_LZ4) { return out }
        }

        throw ExtractionError.decompressionFailed
    }
}
