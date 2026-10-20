import Foundation
import ImageIO
import PeekabooFoundation
import UniformTypeIdentifiers

public struct ClipboardImageInput: Sendable {
    public let data: Data
    public let source: ClipboardImageContents.Source

    public static func validate(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw Self.refusal("Clipboard images must contain at most 10 MiB of complete image data.")
        }
        guard let image = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let detected = CGImageSourceGetType(image),
            [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(detected as String),
            let mime = UTType(detected as String)?.preferredMIMEType,
            CGImageSourceGetCount(image) == 1,
            CGImageSourceGetStatus(image) == .statusComplete,
            CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
            let width = Self.dimension(properties[kCGImagePropertyPixelWidth]),
            let height = Self.dimension(properties[kCGImagePropertyPixelHeight]),
            width <= 64_000_000 / height
        else {
            throw Self.refusal("Clipboard images require one complete PNG, JPEG, or TIFF frame of at most 64 million pixels.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw Self.refusal("The image has an unsupported orientation.")
        }
        try Task.checkCancellation()
        // Decode completely before admission; the original bytes, including orientation and alpha, are written.
        guard let decoded = CGImageSourceCreateImageAtIndex(image, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), decoded.width == width, decoded.height == height,
            CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete
        else {
            throw Self.refusal("The image could not be decoded completely.")
        }
        try Task.checkCancellation()
        return .init(data: data, source: .init(
            uti: detected as String, mimeType: mime, bytes: data.count,
            width: width, height: height, orientation: orientation))
    }

    private static func dimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= 64_000_000, value.rounded() == value else { return nil }
        return Int(value)
    }

    private static func refusal(_ message: String) -> DesktopActionFailure {
        .preDispatchRefusal(reason: .invalidRequest, message: message)
    }
}
