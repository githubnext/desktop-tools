import AppKit
import CoreGraphics
import DesktopProtocol
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The largest JPEG one result carries; a hosted channel stores the whole result in a 2 MB row.
public let maxImage = 900_000

extension Mac {
	/// One window's pixels at one pixel per point, without its shadow, as Peekaboo captures them.
	public static func captureWindow(_ windowID: Int, bounds: CGRect) async throws -> CGImage {
		guard CGPreflightScreenCaptureAccess() else {
			throw ToolError("permissionDenied: Screen Recording access is off for the Desktop Tools host.")
		}
		guard let window = try await scWindow(CGWindowID(windowID)) else {
			throw ToolError("notFound: Window \(windowID) is not available to ScreenCaptureKit.")
		}
		let config = SCStreamConfiguration()
		config.width = Int(bounds.width.rounded())
		config.height = Int(bounds.height.rounded())
		config.captureResolution = .best
		config.ignoreShadowsSingleWindow = true
		config.scalesToFit = true
		config.includeChildWindows = false
		config.showsCursor = false
		config.shouldBeOpaque = true
		config.backgroundColor = .clear
		let image: CGImage = try await SCScreenshotManager.captureImage(
			contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
		)
		guard image.width == config.width, image.height == config.height else {
			throw ToolError("internalError: Exact window capture returned \(image.width)x\(image.height) pixels; expected \(config.width)x\(config.height). Refusing a raster whose extent cannot be mapped to that window.")
		}
		return image
	}

	/// ScreenCaptureKit's window by ID. Its private per-window lookup takes about half as long as listing
	/// all shareable content, so try it first.
	static func scWindow(_ id: CGWindowID) async throws -> SCWindow? {
		let selector = NSSelectorFromString("fetchWindowForWindowID:withCompletionHandler:")
		if let type = NSClassFromString("SCShareableContent") as? NSObject.Type, type.responds(to: selector),
		   let method = type.method(for: selector)
		{
			typealias Fetch = @convention(c) (AnyObject, Selector, UInt32, @escaping @convention(block) (SCWindow?, Error?) -> Void) -> Void
			let fetch = unsafeBitCast(method, to: Fetch.self)
			let box: Box<SCWindow?> = await withCheckedContinuation { continuation in
				fetch(type, selector, id) { window, _ in continuation.resume(returning: Box(window)) }
			}
			if let window = box.value { return window }
		}
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
		return content.windows.first { $0.windowID == id }
	}

	/// A JPEG at quality 70 no larger than `maxImage`, scaled down to 1600, 1200 or 800 pixels on its longest
	/// side when needed but never up.
	public static func jpeg(_ image: CGImage) throws -> (data: Data, width: Int, height: Int) {
		let longest = max(image.width, image.height)
		var sizes: [Int] = []
		for size in [1600, 1200, 800].map({ min($0, longest) }) where !sizes.contains(size) { sizes.append(size) }
		for size in sizes {
			let scaled = size < longest ? resize(image, longest: size) : image
			guard let scaled else { continue }
			let data = NSMutableData()
			guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
			CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
			guard CGImageDestinationFinalize(destination) else { break }
			if data.length <= maxImage { return (data as Data, scaled.width, scaled.height) }
		}
		throw ToolError("The screenshot could not be resized within the result limit.")
	}

	private static func resize(_ image: CGImage, longest: Int) -> CGImage? {
		let scale = Double(longest) / Double(max(image.width, image.height))
		let width = max(1, Int((Double(image.width) * scale).rounded()))
		let height = max(1, Int((Double(image.height) * scale).rounded()))
		guard let context = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else { return nil }
		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}
}

/// Carries a ScreenCaptureKit object, which isn't Sendable, out of its completion handler.
private final class Box<T>: @unchecked Sendable {
	let value: T
	init(_ value: T) { self.value = value }
}
