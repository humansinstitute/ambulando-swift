import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photo preparation for chat attachments, following NoteToSelf's `NotePrivacy.image` (sol/native/NoteToSelf/Privacy.swift):
/// only rendered, orientation-corrected pixels go into a fresh PNG, and every PNG chunk other than pixel and colour data
/// (EXIF, text, time, GPS-bearing metadata) is dropped. The long edge is capped so a camera photo stays a reasonable size.
public enum ImagePrivacy {
    public enum Failure: Error, Equatable { case unreadable, encode }
    public static let maxPixelSize = 4096

    public static func strippedPNG(_ data: Data, maxPixelSize: Int = maxPixelSize) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize)] as CFDictionary)
        else { throw Failure.unreadable }
        let output = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encode }
        CGImageDestinationAddImage(target, image, [:] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw Failure.encode }
        return try keepPixelChunks(output as Data)
    }

    /// ImageIO can synthesise an eXIf block; keep only pixel and colour-rendering chunks.
    static func keepPixelChunks(_ encoded: Data) throws -> Data {
        let bytes = [UInt8](encoded)
        guard bytes.count > 8 else { throw Failure.encode }
        var clean = Data(bytes[0..<8])
        var offset = 8
        let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM"]
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { throw Failure.encode }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if allowed.contains(type) { clean.append(contentsOf: bytes[offset..<offset + length + 12]) }
            offset += length + 12
        }
        guard offset == bytes.count else { throw Failure.encode }
        return clean
    }

    /// PNG chunk types present in `data` (used by tests to prove metadata is gone).
    public static func chunkTypes(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var offset = 8, types: [String] = []
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            types.append(String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self))
            offset += length + 12
        }
        return types
    }

    /// Writes stripped bytes into the staging directory (protected until first unlock) and describes the attachment.
    public static func stage(_ png: Data, in staging: URL, filename: String) throws -> PendingAttachment {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let name = "\(id).png"
        #if os(iOS)
        try png.write(to: staging.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try png.write(to: staging.appendingPathComponent(name), options: [.atomic])
        #endif
        return PendingAttachment(id: id, filename: filename, mimeType: "image/png", sizeBytes: png.count, sha256: SHA256Hex.of(png), staged: name)
    }
}
