import CoreGraphics
import DesktopProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Ported from src/capture-file.ts: save_path, overwrite and region on desktop_inspect and desktop_screen.

/// Where a capture is saved, checked before anything is captured.
struct SaveRequest: Sendable {
	let path: String
	let overwrite: Bool
	let region: CGRect?
	/// The region as the caller gave it, echoed in the result.
	let regionJSON: JSON?
}

extension Tools {
	static func saveRequest(_ arguments: JSON, extensions: [String] = ["png"]) throws -> SaveRequest? {
		let overwrite = arguments["overwrite"]
		if let overwrite, overwrite.bool == nil { throw ToolError("Choose overwrite true or false.") }
		guard let value = arguments["save_path"] else {
			if overwrite != nil || arguments["region"] != nil {
				throw ToolError("overwrite and region apply to the saved file; pass save_path too.")
			}
			return nil
		}
		guard let path = value.string, isNormalizedAbsolute(path), path.utf16.count <= 1024, !path.contains("\0"),
		      extensions.contains(String(path.split(separator: ".", omittingEmptySubsequences: false).last!).lowercased())
		else {
			let names = extensions.map { "." + $0 }
			let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names[0]
			throw ToolError("save_path must be a normalized absolute path ending in \(list).")
		}
		var region: CGRect?
		if let value = arguments["region"] { region = try regionOf(value) }
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent, isDirectory: &isDirectory),
		      isDirectory.boolValue
		else { throw ToolError("save_path's folder must already exist.") }
		var status = stat()
		if lstat(path, &status) == 0 {
			guard status.st_mode & S_IFMT == S_IFREG else {
				throw ToolError("save_path names something other than a regular file; nothing was written.")
			}
			guard overwrite?.bool == true else {
				throw ToolError("save_path already exists; pass overwrite true to replace it. Nothing was captured.")
			}
		}
		return SaveRequest(path: path, overwrite: overwrite?.bool == true, region: region, regionJSON: arguments["region"])
	}

	/// What Node's path.normalize leaves unchanged: no empty, `.` or `..` components.
	private static func isNormalizedAbsolute(_ path: String) -> Bool {
		guard path.hasPrefix("/"), path.count > 1 else { return path == "/" }
		return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
	}

	private static func regionOf(_ value: JSON) throws -> CGRect {
		guard let keys = value.keys, keys.count == 4,
		      let x = value["x"]?.number, let y = value["y"]?.number, let width = value["width"]?.number, let height = value["height"]?.number,
		      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
		else { throw ToolError("region must be x, y, width and height in global desktop points, with positive size.") }
		return CGRect(x: x, y: y, width: width, height: height)
	}

	/// Writes the full-resolution capture, or the part of it under the region, as a PNG. `area` is the capture's
	/// extent in global desktop points; the capture's own pixels map onto it, so nothing is scaled.
	static func save(_ image: CGImage, area: CGRect?, _ request: SaveRequest) throws -> JSON {
		var output = image
		if let region = request.region {
			guard let area, area.width > 0, area.height > 0 else {
				throw ToolError("This capture reported no desktop bounds, so a region can't be located in it.")
			}
			// Half a point of slack absorbs rounding in reported bounds; the crop still stays inside the image.
			let slack = 0.5
			guard region.minX >= area.minX - slack, region.minY >= area.minY - slack,
			      region.maxX <= area.maxX + slack, region.maxY <= area.maxY + slack
			else {
				throw ToolError("region must lie inside the captured area, x \(jsNumber(area.minX)), y \(jsNumber(area.minY)), width \(jsNumber(area.width)), height \(jsNumber(area.height)) in desktop points.")
			}
			let scaleX = Double(image.width) / area.width
			let scaleY = Double(image.height) / area.height
			let left = max(0, Int(((region.minX - area.minX) * scaleX).rounded(.toNearestOrAwayFromZero)))
			let top = max(0, Int(((region.minY - area.minY) * scaleY).rounded(.toNearestOrAwayFromZero)))
			let width = min(image.width - left, Int((region.width * scaleX).rounded(.toNearestOrAwayFromZero)))
			let height = min(image.height - top, Int((region.height * scaleY).rounded(.toNearestOrAwayFromZero)))
			guard width >= 1, height >= 1, let cropped = image.cropping(to: CGRect(x: left, y: top, width: width, height: height)) else {
				throw ToolError("region covers less than one pixel of the capture.")
			}
			output = cropped
		}
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
			throw ToolError("The capture could not be encoded as PNG.")
		}
		CGImageDestinationAddImage(destination, output, nil)
		guard CGImageDestinationFinalize(destination) else { throw ToolError("The capture could not be encoded as PNG.") }
		// Exclusive unless overwrite was asked for, so a file created since validation is never replaced.
		try (data as Data).write(to: URL(fileURLWithPath: request.path), options: request.overwrite ? .atomic : .withoutOverwriting)
		return .object([
			("path", JSON(request.path)), ("width", JSON(output.width)), ("height", JSON(output.height)),
			("region", request.regionJSON ?? .null),
		])
	}

	/// A number as JavaScript prints it, without a trailing `.0`.
	static func jsNumber(_ value: Double) -> String {
		value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
	}
}
