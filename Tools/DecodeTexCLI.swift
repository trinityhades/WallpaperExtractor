import AppKit
import Foundation

// Simple CLI to decode TEX files using project TexDecoder and save PNGs
// Usage: decode_tex --input <folder> --output <folder>

@main
struct Main {
    static func usage() {
        fputs("Usage: decode_tex --input <folder> --output <folder>\n", stderr)
    }

    struct Args {
        var input: URL
        var output: URL
    }

    static func parseArgs() -> Args? {
        var input: String?
        var output: String?
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--input": input = it.next()
            case "--output": output = it.next()
            default: break
            }
        }
        guard let i = input, let o = output else { return nil }
        return Args(input: URL(fileURLWithPath: i), output: URL(fileURLWithPath: o))
    }

    static func savePNG(_ image: NSImage, to url: URL) throws {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(
                domain: "DecodeTexCLI", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "CGImage nil"])
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "DecodeTexCLI", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func main() {
        guard let args = parseArgs() else {
            usage()
            exit(1)
        }

        let fm = FileManager.default
        guard
            let items = try? fm.contentsOfDirectory(
                at: args.input, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            fputs("Failed to read input folder\n", stderr)
            exit(2)
        }

        var ok = 0
        var fail = 0
        for file in items where file.pathExtension.lowercased() == "tex" {
            do {
                let data = try Data(contentsOf: file)
                if let img = try TexDecoder.decode(data) {
                    let out = args.output.appendingPathComponent(
                        file.deletingPathExtension().lastPathComponent + ".png")
                    try savePNG(img, to: out)
                    let attrs = try? fm.attributesOfItem(atPath: out.path)
                    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                    print("✅ \(file.lastPathComponent) -> \(out.lastPathComponent) (\(size) bytes)")
                    ok += 1
                } else {
                    print("ℹ️ Skipped (video or unsupported): \(file.lastPathComponent)")
                }
            } catch {
                print("❌ Decode failed for \(file.lastPathComponent): \(error)")
                fail += 1
            }
        }

        print("Done. Success: \(ok), Failed: \(fail)")
    }
}
