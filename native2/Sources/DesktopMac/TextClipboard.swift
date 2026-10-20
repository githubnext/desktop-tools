import AppKit
import DesktopProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The general pasteboard, ported from Peekaboo's ClipboardService, ClipboardImageContents, ClipboardImageInput
// and ClipboardFilesInput (MIT). Reads are refused unless macOS lets this host read silently, and every read is
// bound to one change count, so a clipboard that changes mid-read is never reported half-read.

private func onMain<T>(_ work: () throws -> T) rethrows -> T {
	if Thread.isMainThread { return try work() }
	return try DispatchQueue.main.sync(execute: work)
}

/// A refused read, as the Node server words a host's invalid-input error.
private func readRefusal(_ message: String) -> ToolError { ToolError("invalidRequest: \(message).") }

private let maximumImageBytes = 10 * 1024 * 1024
private let maximumPixels = 64_000_000
private let maximumPreviewBytes = 900_000

/// The decoded image a write or read is about, as ClipboardImageContents.Source encodes it.
public struct ClipboardImageSource: Sendable {
	public let uti: String
	public let mimeType: String
	public let bytes: Int
	public let width: Int
	public let height: Int
	public let orientation: Int
	public var json: JSON {
		.object([
			("uti", JSON(uti)), ("mimeType", JSON(mimeType)), ("bytes", JSON(bytes)), ("width", JSON(width)),
			("height", JSON(height)), ("orientation", JSON(orientation)),
		])
	}
}

private func dimension(_ value: Any?) -> Int? {
	guard let number = value as? NSNumber else { return nil }
	let value = number.doubleValue
	guard value.isFinite, value > 0, value <= Double(maximumPixels), value.rounded() == value else { return nil }
	return Int(value)
}

/// One complete PNG, JPEG or TIFF frame's source and its metadata, or nil when the data isn't one.
private func imageSource(_ data: Data, uti expected: String?) -> (CGImageSource, ClipboardImageSource, orientationOK: Bool)? {
	guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
	      let detected = CGImageSourceGetType(source) as String?,
	      expected.map({ $0 == detected }) ?? [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(detected),
	      let mime = UTType(detected)?.preferredMIMEType,
	      CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
	      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
	      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
	      let width = dimension(properties[kCGImagePropertyPixelWidth]), let height = dimension(properties[kCGImagePropertyPixelHeight]),
	      width <= maximumPixels / height
	else { return nil }
	let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
	return (source, ClipboardImageSource(uti: detected, mimeType: mime, bytes: data.count, width: width, height: height, orientation: orientation), (1...8).contains(orientation))
}

private func encode(_ image: CGImage, as format: UTType) -> Data? {
	let data = NSMutableData()
	guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return nil }
	CGImageDestinationAddImage(destination, image, format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary : nil)
	return CGImageDestinationFinalize(destination) ? data as Data : nil
}

private func onWhite(_ image: CGImage) throws -> CGImage {
	guard let color = CGColorSpace(name: CGColorSpace.sRGB),
	      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
	else { throw readRefusal("The clipboard image preview could not be rendered.") }
	let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
	context.setFillColor(CGColor(gray: 1, alpha: 1))
	context.fill(bounds)
	context.draw(image, in: bounds)
	guard let result = context.makeImage() else { throw readRefusal("The clipboard image preview could not be rendered.") }
	return result
}

/// A clipboard image read: its source, and a preview of at most 1600 px and 900 KB.
public struct ClipboardImageRead: Sendable {
	public let changeCount: Int
	public let source: ClipboardImageSource?
	/// The preview's metadata, as Node returns it, without its data.
	public let preview: JSON?
	public let previewData: String?
	public let previewMimeType: String?
	public let original: Data?
}

private struct ClipboardWriteOutcome {
	let changed: Bool
	let verified: Bool
}

extension Mac {
	/// Whether macOS lets this host read the general pasteboard without asking; before macOS 15.4 it always may.
	static func clipboardReadAdmitted() -> Bool {
		guard #available(macOS 15.4, *) else { return true }
		return onMain { NSPasteboard.general.accessBehavior == .alwaysAllow }
	}

	private static func requireReadAccess() throws {
		guard clipboardReadAdmitted() else {
			throw ToolError("permissionDenied: Programmatic clipboard reads require silently allowed access.. Check the clipboard access of Desktop Tools in macOS Settings.")
		}
	}

	private static func promised(_ item: NSPasteboardItem) -> Bool {
		item.types.isEmpty || item.types.contains { $0.rawValue.localizedCaseInsensitiveContains("promise") }
	}

	/// The clipboard's plain text, or present false when it holds none.
	public static func readClipboardText() throws -> JSON {
		try requireReadAccess()
		return try onMain {
			let pasteboard = NSPasteboard.general
			let generation = pasteboard.changeCount
			guard let items = pasteboard.pasteboardItems, items.count <= 1 else {
				throw readRefusal("Plain-text reads require a complete clipboard with at most one item.")
			}
			var text: String?
			if let item = items.first {
				guard !promised(item) else {
					throw readRefusal("Clipboard file promises or unavailable representations cannot be read as plain text.")
				}
				if item.types.contains(.string) {
					guard let value = item.string(forType: .string) else {
						throw readRefusal("The advertised plain-text representation could not be read completely.")
					}
					guard value.utf16.count <= 24_000 else { throw readRefusal("Clipboard text exceeds the complete 24 KB result limit.") }
					text = value
				}
			} else if pasteboard.types?.isEmpty != true {
				throw readRefusal("The clipboard item inventory is unavailable.")
			}
			guard pasteboard.changeCount == generation else {
				throw readRefusal("The clipboard changed during the read; request a fresh read.")
			}
			let result = JSON.object(["present": JSON(text != nil), "text": text.map(JSON.string), "change_count": JSON(generation)])
			guard result.text.utf8.count <= 24_000 else { throw readRefusal("Clipboard text exceeds the complete 24 KB result limit.") }
			return result
		}
	}

	/// The clipboard's file references, or present false when it holds none.
	public static func readClipboardFiles() throws -> JSON {
		try requireReadAccess()
		return try onMain {
			let pasteboard = NSPasteboard.general
			let generation = pasteboard.changeCount
			guard let items = pasteboard.pasteboardItems, items.count <= 32 else {
				throw readRefusal("File reads require a complete clipboard with at most 32 items.")
			}
			var files: [JSON] = []
			for item in items {
				guard !promised(item) else {
					throw readRefusal("Clipboard file promises or unavailable representations cannot be read as file references.")
				}
				guard item.types.contains(.fileURL) else {
					guard !item.types.contains(where: { $0.rawValue == "NSFilenamesPboardType" }) else {
						throw readRefusal("Legacy filename lists are unsupported; copy advertised file URL items.")
					}
					continue
				}
				guard let data = item.data(forType: .fileURL), data.count <= 24_000, let raw = String(data: data, encoding: .utf8) else {
					throw readRefusal("The advertised file URL could not be read completely within 24 KB.")
				}
				guard let url = URL(string: raw, encodingInvalidCharacters: false), url.isFileURL, !(url as NSURL).isFileReferenceURL(),
				      url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
				      url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
				else { throw readRefusal("Clipboard files require ordinary absolute local file URLs.") }
				let path = url.path(percentEncoded: false)
				guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw readRefusal("Clipboard files require ordinary absolute local file URLs.") }
				files.append(.object([("url", JSON(raw)), ("path", JSON(path))]))
			}
			guard files.isEmpty || files.count == items.count else {
				throw readRefusal("Clipboard file reads do not omit mixed non-file items.")
			}
			if items.isEmpty, pasteboard.types?.isEmpty != true { throw readRefusal("The clipboard item inventory is unavailable.") }
			guard pasteboard.changeCount == generation else {
				throw readRefusal("The clipboard changed during the read; request a fresh read.")
			}
			let result = JSON.object(["present": JSON(!files.isEmpty), "files": files.isEmpty ? nil : .array(files), "change_count": JSON(generation)])
			guard result.text.utf8.count <= 24_000 else { throw readRefusal("Clipboard file references exceed the complete 24 KB result limit.") }
			return result
		}
	}

	/// The clipboard's one PNG, JPEG or TIFF image as a bounded preview, with its original bytes when asked.
	public static func readClipboardImage(original: Bool) throws -> ClipboardImageRead {
		try requireReadAccess()
		let (generation, found): (Int, (Data, String)?) = try onMain {
			let pasteboard = NSPasteboard.general
			let generation = pasteboard.changeCount
			guard let items = pasteboard.pasteboardItems, items.count <= 1 else {
				throw readRefusal("Image reads require a complete clipboard with at most one item.")
			}
			var found: (Data, String)?
			if let item = items.first {
				guard !promised(item) else {
					throw readRefusal("Clipboard file promises or unavailable representations cannot be read as an image.")
				}
				if let type = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].first(where: { item.types.contains(.init($0)) }) {
					guard let data = item.data(forType: .init(type)) else {
						throw readRefusal("The advertised image representation could not be read completely.")
					}
					found = (data, type)
				} else if item.types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true }) {
					throw readRefusal("Clipboard image reads support PNG, JPEG, or TIFF.")
				}
			} else if pasteboard.types?.isEmpty != true {
				throw readRefusal("The clipboard item inventory is unavailable.")
			}
			guard pasteboard.changeCount == generation else {
				throw readRefusal("The clipboard changed during the read; request a fresh read.")
			}
			return (generation, found)
		}
		guard let (data, uti) = found else {
			return ClipboardImageRead(changeCount: generation, source: nil, preview: nil, previewData: nil, previewMimeType: nil, original: nil)
		}
		guard !data.isEmpty, data.count <= maximumImageBytes else {
			throw readRefusal("Clipboard image data must fit the complete 10 MiB source limit.")
		}
		guard let (source, metadata, orientationOK) = imageSource(data, uti: uti) else {
			throw readRefusal("Clipboard images require one complete PNG, JPEG, or TIFF frame of at most 64 million pixels.")
		}
		guard orientationOK else { throw readRefusal("The clipboard image has an unsupported orientation.") }
		// Prefer a lossless transparent preview at each bounded size before flattening for JPEG.
		for format in [UTType.png, UTType.jpeg] {
			var previous = 0
			for bound in [1600, 1200, 800] {
				let size = min(bound, max(metadata.width, metadata.height))
				if size == previous { continue }
				previous = size
				guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
					kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
					kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceShouldCacheImmediately: true,
				] as CFDictionary), thumbnail.width > 0, thumbnail.height > 0, thumbnail.width <= 1600, thumbnail.height <= 1600,
					CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
				else { throw readRefusal("The clipboard image could not be decoded completely.") }
				let jpeg = format == .jpeg
				let image = try jpeg ? onWhite(thumbnail) : thumbnail
				guard let encoded = encode(image, as: format) else { throw readRefusal("The clipboard image preview could not be encoded.") }
				if encoded.count > maximumPreviewBytes { continue }
				guard onMain({ NSPasteboard.general.changeCount }) == generation else {
					throw readRefusal("The clipboard changed during the read; request a fresh read.")
				}
				let mime = jpeg ? "image/jpeg" : "image/png"
				let preview = JSON.object([
					"mimeType": JSON(mime), "bytes": JSON(encoded.count), "width": JSON(image.width), "height": JSON(image.height),
					"resized": JSON(max(metadata.width, metadata.height) > max(image.width, image.height)), "reencoded": true,
					"background": jpeg ? "white" : nil,
				])
				return ClipboardImageRead(changeCount: generation, source: metadata, preview: preview, previewData: encoded.base64EncodedString(), previewMimeType: mime, original: original ? data : nil)
			}
		}
		throw readRefusal("The clipboard image preview exceeds the complete 900 KB result limit.")
	}

	// MARK: Writes

	/// Checks image bytes before they replace the clipboard: one complete frame that decodes in full.
	public static func clipboardImageInput(_ data: Data) throws -> ClipboardImageSource {
		func refused(_ message: String) -> Refusal {
			var refusal = Refusal("CLIPBOARD_WRITE_FAILED", message)
			refusal.reason = "invalid_request"
			return refusal
		}
		guard !data.isEmpty, data.count <= maximumImageBytes else {
			throw refused("Clipboard images must contain at most 10 MiB of complete image data.")
		}
		guard let (source, metadata, orientationOK) = imageSource(data, uti: nil) else {
			throw refused("Clipboard images require one complete PNG, JPEG, or TIFF frame of at most 64 million pixels.")
		}
		guard orientationOK else { throw refused("The image has an unsupported orientation.") }
		guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
		      decoded.width == metadata.width, decoded.height == metadata.height, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
		else { throw refused("The image could not be decoded completely.") }
		return metadata
	}

	/// File URLs for absolute paths, percent-encoded literally without resolving links or touching the disk.
	public static func clipboardFileURLs(_ paths: [String]) throws -> [String] {
		func refused(_ message: String) -> Refusal {
			var refusal = Refusal("CLIPBOARD_WRITE_FAILED", message)
			refusal.reason = "invalid_request"
			return refusal
		}
		guard (1...32).contains(paths.count) else { throw refused("Clipboard file writes require 1–32 absolute paths.") }
		let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
		let urls = try paths.map { path in
			guard path.hasPrefix("/"), path.utf16.count <= 4096, !path.utf8.contains(0), let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
				throw refused("Clipboard file writes require absolute paths of at most 4096 UTF-16 units without NUL.")
			}
			let raw = "file://" + encoded
			guard let url = URL(string: raw, encodingInvalidCharacters: false), url.isFileURL, url.host == nil || url.host == "", !(url as NSURL).isFileReferenceURL() else {
				throw refused("Clipboard file writes require ordinary local file references.")
			}
			return raw
		}
		let largest = JSON.object([
			("present", true), ("files", .array(zip(urls, paths).map { .object([("url", JSON($0)), ("path", JSON($1))]) })), ("change_count", 0),
		])
		// The read result's change count can take up to 19 digits, as Int.max does.
		guard largest.text.utf8.count + 18 <= 24_000 else { throw refused("Clipboard file references exceed the complete 24 KB read-result limit.") }
		return urls
	}

	/// The outcome of a clipboard write: confirmed when this host could read its own write back.
	private static func clipboardDelivery(_ verified: Bool) -> Delivery {
		var delivery = verified
			? Delivery(state: .confirmedChange, mechanism: "clipboard_transaction", evidence: "verified_change", units: nil)
			: Delivery(state: .dispatchedUnverified, mechanism: "clipboard_transaction", evidence: "delivery_accepted", units: nil)
		delivery.mode = "foreground"
		return delivery
	}

	/// Replaces the clipboard with representations, each type declared first, then reads them back.
	private static func writeRepresentations(_ representations: [(String, Data)], text: String?) throws -> Delivery {
		try onMain {
			let pasteboard = NSPasteboard.general
			var types = representations.map { NSPasteboard.PasteboardType($0.0) }
			if text != nil, !types.contains(.string) { types.append(.string) }
			pasteboard.declareTypes(types, owner: nil)
			for (type, data) in representations where !pasteboard.setData(data, forType: .init(type)) {
				throw Indeterminate(clipboardIndeterminate, code: "CLIPBOARD_WRITE_FAILED", "Clipboard set may have changed the clipboard, but post-write processing failed.", hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.", cause: "Unable to set type \(type)")
			}
			if let text { pasteboard.setString(text, forType: .string) }
			let normalized = { (value: String) in value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
			let verified = clipboardReadAdmitted() && representations.allSatisfy { type, data in
				guard let actual = pasteboard.data(forType: .init(type)) else { return false }
				if [UTType.plainText.identifier, UTType.utf8PlainText.identifier].contains(type),
				   let a = String(data: actual, encoding: .utf8), let b = String(data: data, encoding: .utf8)
				{ return normalized(a) == normalized(b) }
				return actual == data
			}
			return clipboardDelivery(verified)
		}
	}

	private static var clipboardIndeterminate: Delivery {
		var delivery = Delivery(state: .indeterminate, mechanism: "clipboard_transaction", evidence: "completion_unknown", units: nil)
		delivery.mode = "foreground"
		return delivery
	}

	/// Replaces the clipboard with plain text.
	public static func writeClipboardText(_ text: String) throws -> Delivery {
		let data = Data(text.utf8)
		return try writeRepresentations([(UTType.plainText.identifier, data), (NSPasteboard.PasteboardType.string.rawValue, data)], text: text)
	}

	/// Replaces the clipboard with one image's original bytes, under its own type.
	public static func writeClipboardImage(_ data: Data, source: ClipboardImageSource) throws -> Delivery {
		try writeRepresentations([(source.uti, data)], text: nil)
	}

	/// Replaces the clipboard with one file reference item per URL.
	public static func writeClipboardFiles(_ urls: [String]) throws -> Delivery {
		try onMain {
			let pasteboard = NSPasteboard.general
			let items = urls.map { url in
				let item = NSPasteboardItem()
				item.setData(Data(url.utf8), forType: .fileURL)
				return item
			}
			let claimed = pasteboard.clearContents()
			guard pasteboard.writeObjects(items) else {
				throw Indeterminate(clipboardIndeterminate, code: "CLIPBOARD_WRITE_FAILED", "Clipboard files write may have changed the clipboard, but post-write processing failed.", hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.", cause: "Unable to publish all file reference items")
			}
			let written = pasteboard.pasteboardItems ?? []
			let verified = clipboardReadAdmitted() && pasteboard.changeCount == claimed && written.count == urls.count
				&& zip(written, urls).allSatisfy { $0.types.contains(.fileURL) && $0.data(forType: .fileURL) == Data($1.utf8) }
			return clipboardDelivery(verified)
		}
	}
}
