import Foundation
import AppKit

class TexDecoder {
    struct Header {
        let format: Int32
        let flags: UInt32
        let textureWidth: Int
        let textureHeight: Int
        let imageWidth: Int
        let imageHeight: Int
    }

    static func decode(_ data: Data) throws -> NSImage? {
        var p = 0

        func readNString(max: Int) -> String? {
            guard p < data.count else { return nil }
            let end = (max == Int.max) ? data.count : min(data.count, p + max)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(min(1024, max))
            while p < end {
                let b = data[p]
                p += 1
                if b == 0 { break }
                bytes.append(b)
            }
            return String(bytes: bytes, encoding: .utf8)
        }

        func readI32() -> Int32? {
            guard p + 4 <= data.count else { return nil }
            let v: Int32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: Int32.self) }
            p += 4
            return v
        }
        func readU32() -> UInt32? {
            guard p + 4 <= data.count else { return nil }
            let v: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt32.self) }
            p += 4
            return v
        }

        // Magic strings
        guard let magic1 = readNString(max: 16), magic1 == "TEXV0005" else { return nil }
        guard let magic2 = readNString(max: 16), magic2 == "TEXI0001" else { return nil }

        // Header
        guard let format = readI32(),
              let flagsI = readI32(),
              let texW = readI32(),
              let texH = readI32(),
              let imgW = readI32(),
              let imgH = readI32(),
              readU32() != nil else { return nil }

        let header = Header(
            format: format,
            flags: UInt32(bitPattern: flagsI),
            textureWidth: Int(texW),
            textureHeight: Int(texH),
            imageWidth: Int(imgW),
            imageHeight: Int(imgH)
        )

        guard header.textureWidth > 0, header.textureHeight > 0 else { return nil }

        // Container
        guard let containerMagic = readNString(max: 16) else { return nil }
        guard let imageCountI = readI32() else { return nil }
        let imageCount = Int(imageCountI)
        guard imageCount > 0 && imageCount < 4096 else { return nil }

        // Version specifics
        var containerVersion = 0
        var containerImageFormat: Int = -1 // FreeImageFormat, -1 = unknown
        var isVideoMp4 = false
        if containerMagic.hasPrefix("TEXB") {
            if let v = Int(containerMagic.suffix(4)) { containerVersion = v }
        }

        if containerVersion == 3 {
            // image format value (FreeImageFormat)
            if let fmt = readI32() { containerImageFormat = Int(fmt) }
        } else if containerVersion == 4 {
            // TEXB0004: format (FreeImageFormat) and isVideoMp4 flag
            if let fmt = readI32() { containerImageFormat = Int(fmt) }
            if let mp4 = readI32() { isVideoMp4 = (mp4 == 1) }
            // If it's MP4 and format is unknown, set to MP4
            if containerImageFormat == -1 && isVideoMp4 {
                containerImageFormat = 35
            }
            // RePKG treats v4 as v3 for non-MP4 images (no extra params to read)
        }

        // Read first image only
        guard let mipCountI = readI32() else { return nil }
        let mipCount = Int(mipCountI)
        guard mipCount > 0 && mipCount < 64 else { return nil }

        // Read first mipmap depending on version
        var mipWidth = 0
        var mipHeight = 0
        var bytes = Data()

        func readBytesBlock() -> Data? {
            guard let countI = readI32() else { return nil }
            let count = Int(countI)
            guard count >= 0, p + count <= data.count else { return nil }
            let sub = data.subdata(in: p..<p+count)
            p += count
            return sub
        }

        if containerVersion == 1 {
            guard let w = readI32(), let h = readI32(), let b = readBytesBlock() else { return nil }
            mipWidth = Int(w); mipHeight = Int(h); bytes = b
        } else {
            // v2 or v3
            guard let w = readI32(),
                  let h = readI32(),
                  let isLZ4I = readI32(),
                  let decompSizeI = readI32(),
                  let b = readBytesBlock() else { return nil }
            mipWidth = Int(w); mipHeight = Int(h)
            let isLZ4 = (isLZ4I == 1)
            if isLZ4 {
                let decompSize = Int(decompSizeI)
                // Sanity bounds: prevent huge allocations/overflow
                guard decompSize > 0 && decompSize <= 512 * 1024 * 1024 else { return nil }
                bytes = try LZ4Decompressor.decompress(b, outputSize: decompSize)
            } else {
                bytes = b
            }
        }

        // Validate mip dimensions to avoid overflows
        guard mipWidth > 0, mipHeight > 0, mipWidth <= 16384, mipHeight <= 16384 else { return nil }

        // Check if the data is actually a video file by looking for MP4 signature
        let isActuallyMP4 = bytes.count > 12 && (
            (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) // "ftyp"
        )

        // Skip video files - we can't convert them to PNG
        if isActuallyMP4 || (isVideoMp4 && containerImageFormat == 35) {
            return nil
        }

        // If container specifies a standard image format (PNG/JPEG/etc.), bytes are the encoded image
        // FreeImageFormat.FIF_UNKNOWN = -1, FIF_MP4 = 35
        if containerImageFormat != -1 {
            if let img = NSImage(data: bytes) { return img }
            // As a fallback, try ImageIO via CGImageSource (in case of uncommon headers)
            if let src = CGImageSourceCreateWithData(bytes as CFData, nil),
               CGImageSourceGetCount(src) > 0,
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return NSImage(cgImage: cg, size: .zero)
            }
            return nil
        }

        // Choose decode based on TexFormat
        switch header.format {
        case 0: // RGBA8888
            return decodeRGBA8888(bytes, width: mipWidth, height: mipHeight)
        case 4: // DXT5
            return decodeDXT5(bytes, width: mipWidth, height: mipHeight)
        case 6: // DXT3
            return decodeDXT3(bytes, width: mipWidth, height: mipHeight)
        case 7: // DXT1
            return decodeDXT1(bytes, width: mipWidth, height: mipHeight)
        case 8: // RG88 (2 channels)
            return decodeRG88(bytes, width: mipWidth, height: mipHeight)
        case 9: // R8 (1 channel - grayscale)
            return decodeR8(bytes, width: mipWidth, height: mipHeight)
        default:
            return nil
        }
    }

    private static func decodeRGBA8888(_ data: Data, width: Int, height: Int) -> NSImage? {
        let bytesPerPixel = 4
        // Use 64-bit math to avoid overflow, then validate against reasonable caps
        let expectedSize64 = Int64(width) * Int64(height) * Int64(bytesPerPixel)
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              expectedSize64 > 0, expectedSize64 <= Int64(data.count), expectedSize64 <= Int64(Int.max) else {
            return nil
        }
        let expectedSize = Int(expectedSize64)

        var rgbaData = Data(count: expectedSize)
        rgbaData.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                destPtr.copyMemory(from: UnsafeRawBufferPointer(start: srcPtr.baseAddress, count: expectedSize))
            }
        }

        return createImage(from: rgbaData, width: width, height: height)
    }

    private static func decodeDXT1(_ data: Data, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }

        let blockWidth = (width + 3) / 4
        let blockHeight = (height + 3) / 4
        let expectedSize = blockWidth * blockHeight * 8

        guard data.count >= expectedSize else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        var blockIndex = 0

        for by in 0..<blockHeight {
            for bx in 0..<blockWidth {
                let blockOffset = blockIndex * 8
                guard blockOffset + 8 <= data.count else { continue }

                let c0 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset, as: UInt16.self) }
                let c1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 2, as: UInt16.self) }
                let codes = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 4, as: UInt32.self) }

                let colors = interpolateDXT1Colors(c0, c1)

                for y in 0..<4 {
                    for x in 0..<4 {
                        let px = bx * 4 + x
                        let py = by * 4 + y

                        if px < width && py < height {
                            let codeIndex = (codes >> ((y * 4 + x) * 2)) & 0x3
                            let color = colors[Int(codeIndex)]

                            let pixelIndex = (py * width + px) * 4
                            rgba[pixelIndex] = color.0
                            rgba[pixelIndex + 1] = color.1
                            rgba[pixelIndex + 2] = color.2
                            rgba[pixelIndex + 3] = 255
                        }
                    }
                }

                blockIndex += 1
            }
        }

        return createImage(from: Data(rgba), width: width, height: height)
    }

    private static func decodeDXT3(_ data: Data, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }

        // DXT3 has 16 bytes per block (8 for alpha, 8 for color)
        let blockWidth = (width + 3) / 4
        let blockHeight = (height + 3) / 4
        let expectedSize = blockWidth * blockHeight * 16

        guard data.count >= expectedSize else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        var blockIndex = 0

        for by in 0..<blockHeight {
            for bx in 0..<blockWidth {
                let blockOffset = blockIndex * 16
                guard blockOffset + 16 <= data.count else { continue }

                // Read alpha block (8 bytes)
                let alphaBlock = data.subdata(in: blockOffset..<blockOffset + 8)

                // Read color block (8 bytes)
                let c0 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 8, as: UInt16.self) }
                let c1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 10, as: UInt16.self) }
                let codes = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 12, as: UInt32.self) }

                let colors = interpolateDXT1Colors(c0, c1)

                for y in 0..<4 {
                    for x in 0..<4 {
                        let px = bx * 4 + x
                        let py = by * 4 + y

                        if px < width && py < height {
                            let codeIndex = (codes >> ((y * 4 + x) * 2)) & 0x3
                            let color = colors[Int(codeIndex)]

                            // Extract alpha (4 bits per pixel)
                            let alphaIndex = y * 4 + x
                            let alphaByte = alphaBlock[alphaIndex / 2]
                            let alpha = (alphaIndex % 2 == 0) ? (alphaByte & 0x0F) << 4 : alphaByte & 0xF0

                            let pixelIndex = (py * width + px) * 4
                            rgba[pixelIndex] = color.0
                            rgba[pixelIndex + 1] = color.1
                            rgba[pixelIndex + 2] = color.2
                            rgba[pixelIndex + 3] = alpha
                        }
                    }
                }

                blockIndex += 1
            }
        }

        return createImage(from: Data(rgba), width: width, height: height)
    }

    private static func decodeDXT5(_ data: Data, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }

        // Similar to DXT3 but with interpolated alpha
        let blockWidth = (width + 3) / 4
        let blockHeight = (height + 3) / 4
        let expectedSize = blockWidth * blockHeight * 16

        guard data.count >= expectedSize else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        var blockIndex = 0

        for by in 0..<blockHeight {
            for bx in 0..<blockWidth {
                let blockOffset = blockIndex * 16
                guard blockOffset + 16 <= data.count else { continue }

                let alpha0 = data[blockOffset]
                let alpha1 = data[blockOffset + 1]
                let alphas = interpolateDXT5Alphas(alpha0, alpha1)

                let c0 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 8, as: UInt16.self) }
                let c1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 10, as: UInt16.self) }
                let codes = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: blockOffset + 12, as: UInt32.self) }

                let colors = interpolateDXT1Colors(c0, c1)

                for y in 0..<4 {
                    for x in 0..<4 {
                        let px = bx * 4 + x
                        let py = by * 4 + y

                        if px < width && py < height {
                            let codeIndex = (codes >> ((y * 4 + x) * 2)) & 0x3
                            let color = colors[Int(codeIndex)]

                            let pixelIndex = (py * width + px) * 4
                            rgba[pixelIndex] = color.0
                            rgba[pixelIndex + 1] = color.1
                            rgba[pixelIndex + 2] = color.2
                            rgba[pixelIndex + 3] = alphas[0] // Simplified alpha
                        }
                    }
                }

                blockIndex += 1
            }
        }

        return createImage(from: Data(rgba), width: width, height: height)
    }

    private static func interpolateDXT1Colors(_ c0: UInt16, _ c1: UInt16) -> [(UInt8, UInt8, UInt8)] {
        // Expand 5:6:5 to 8-bit channels using Int math to avoid UInt8 overflow
        let r0i = (Int(c0) >> 11) & 0x1F
        let g0i = (Int(c0) >> 5) & 0x3F
        let b0i = Int(c0) & 0x1F

        let r1i = (Int(c1) >> 11) & 0x1F
        let g1i = (Int(c1) >> 5) & 0x3F
        let b1i = Int(c1) & 0x1F

        // Convert to 8-bit with safe clamping
        let r0 = min(255, (r0i * 255) / 31)
        let g0 = min(255, (g0i * 255) / 63)
        let b0 = min(255, (b0i * 255) / 31)

        let r1 = min(255, (r1i * 255) / 31)
        let g1 = min(255, (g1i * 255) / 63)
        let b1 = min(255, (b1i * 255) / 31)

        let c0t: (UInt8, UInt8, UInt8) = (UInt8(r0), UInt8(g0), UInt8(b0))
        let c1t: (UInt8, UInt8, UInt8) = (UInt8(r1), UInt8(g1), UInt8(b1))

        // Interpolate with safe Int math
        let r2 = min(255, (2 * r0 + r1) / 3)
        let g2 = min(255, (2 * g0 + g1) / 3)
        let b2 = min(255, (2 * b0 + b1) / 3)

        let r3 = min(255, (r0 + 2 * r1) / 3)
        let g3 = min(255, (g0 + 2 * g1) / 3)
        let b3 = min(255, (b0 + 2 * b1) / 3)

        return [
            c0t,
            c1t,
            (UInt8(r2), UInt8(g2), UInt8(b2)),
            (UInt8(r3), UInt8(g3), UInt8(b3))
        ]
    }

    private static func interpolateDXT5Alphas(_ a0: UInt8, _ a1: UInt8) -> [UInt8] {
        var alphas = [a0, a1]
        if a0 > a1 {
            for i in 1...6 {
                alphas.append(UInt8((Int(a0) * (7 - i) + Int(a1) * i) / 7))
            }
        } else {
            for i in 1...4 {
                alphas.append(UInt8((Int(a0) * (5 - i) + Int(a1) * i) / 5))
            }
            alphas.append(0)
            alphas.append(255)
        }
        return alphas
    }

    private static func decodeR8(_ data: Data, width: Int, height: Int) -> NSImage? {
        // R8: 1 byte per pixel (grayscale)
        let expectedSize = width * height
        guard data.count >= expectedSize else { return nil }

        // Convert to RGBA by replicating the R value to RGB
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<expectedSize {
            let gray = data[i]
            rgba[i * 4] = gray
            rgba[i * 4 + 1] = gray
            rgba[i * 4 + 2] = gray
            rgba[i * 4 + 3] = 255
        }

        return createImage(from: Data(rgba), width: width, height: height)
    }

    private static func decodeRG88(_ data: Data, width: Int, height: Int) -> NSImage? {
        // RG88: 2 bytes per pixel (red and green channels)
        let expectedSize = width * height * 2
        guard data.count >= expectedSize else { return nil }

        // Convert to RGBA
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<(width * height) {
            rgba[i * 4] = data[i * 2]         // R
            rgba[i * 4 + 1] = data[i * 2 + 1] // G
            rgba[i * 4 + 2] = 0                // B
            rgba[i * 4 + 3] = 255              // A
        }

        return createImage(from: Data(rgba), width: width, height: height)
    }

    private static func createImage(from data: Data, width: Int, height: Int) -> NSImage? {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        let size = NSSize(width: width, height: height)
        return NSImage(cgImage: cgImage, size: size)
    }
}
