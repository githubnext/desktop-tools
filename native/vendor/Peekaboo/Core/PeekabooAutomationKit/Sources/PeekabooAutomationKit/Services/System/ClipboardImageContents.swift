import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import UniformTypeIdentifiers

public struct ClipboardImageContents: Codable, Sendable {
    public let present: Bool
    public let change_count: Int
    public let source: Source?
    public let image: Preview?
    /// The validated source bytes, present only for an export.
    public var original: Data?

    public struct Source: Codable, Sendable {
        public let uti: String
        public let mimeType: String
        public let bytes: Int
        public let width: Int
        public let height: Int
        public let orientation: Int
    }

    public struct Preview: Codable, Sendable {
        public let data: Data
        public let mimeType: String
        public let bytes: Int
        public let width: Int
        public let height: Int
        public let resized: Bool
        public let reencoded: Bool
        public let background: String?
    }
}

enum ClipboardImageRenderer {
    private static let maximumSourceBytes = 10 * 1024 * 1024
    private static let maximumPixels = 64_000_000
    private static let maximumPreviewBytes = 900_000

    static func render(_ data: Data, uti: String, generation: Int) throws -> ClipboardImageContents {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= self.maximumSourceBytes else {
            throw PeekabooError.invalidInput("Clipboard image data must fit the complete 10 MiB source limit.")
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let detected = CGImageSourceGetType(source),
            detected as String == uti,
            let mimeType = UTType(uti)?.preferredMIMEType,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = self.dimension(properties[kCGImagePropertyPixelWidth]),
            let height = self.dimension(properties[kCGImagePropertyPixelHeight]),
            width <= self.maximumPixels / height
        else {
            throw PeekabooError.invalidInput("Clipboard images require one complete PNG, JPEG, or TIFF frame of at most 64 million pixels.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw PeekabooError.invalidInput("The clipboard image has an unsupported orientation.")
        }
        let metadata = ClipboardImageContents.Source(
            uti: uti, mimeType: mimeType, bytes: data.count, width: width, height: height,
            orientation: orientation)
        // Prefer a lossless transparent preview at each bounded size before flattening for JPEG.
        for format in [UTType.png, UTType.jpeg] {
            var previousSize = 0
            for bound in [1600, 1200, 800] {
                try Task.checkCancellation()
                let size = min(bound, max(width, height))
                if size == previousSize { continue }
                previousSize = size
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary),
                    thumbnail.width > 0, thumbnail.height > 0,
                    thumbnail.width <= 1600, thumbnail.height <= 1600,
                    CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
                else {
                    throw PeekabooError.invalidInput("The clipboard image could not be decoded completely.")
                }
                let jpeg = format == .jpeg
                let image = try jpeg ? self.onWhite(thumbnail) : thumbnail
                let encoded = try self.encode(image, format: format)
                if encoded.count > self.maximumPreviewBytes { continue }
                return ClipboardImageContents(
                    present: true, change_count: generation, source: metadata,
                    image: .init(data: encoded, mimeType: jpeg ? "image/jpeg" : "image/png",
                                 bytes: encoded.count, width: image.width, height: image.height,
                                 resized: max(width, height) > max(image.width, image.height),
                                 reencoded: true, background: jpeg ? "white" : nil))
            }
        }
        throw PeekabooError.invalidInput("The clipboard image preview exceeds the complete 900 KB result limit.")
    }

    private static func dimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(self.maximumPixels), value.rounded() == value else {
            return nil
        }
        return Int(value)
    }

    private static func onWhite(_ image: CGImage) throws -> CGImage {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PeekabooError.invalidInput("The clipboard image preview could not be rendered.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let result = context.makeImage() else {
            throw PeekabooError.invalidInput("The clipboard image preview could not be rendered.")
        }
        return result
    }

    private static func encode(_ image: CGImage, format: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else {
            throw PeekabooError.invalidInput("The clipboard image preview could not be encoded.")
        }
        let options = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw PeekabooError.invalidInput("The clipboard image preview could not be encoded.")
        }
        return data as Data
    }
}
