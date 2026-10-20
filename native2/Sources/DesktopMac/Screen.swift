import AppKit
import CoreGraphics
import DesktopProtocol
import ScreenCaptureKit

// Ported from the native client's screen.swift: the display list and the whole-display capture behind desktop_screen.

/// One active display as desktop_screen and desktop_spaces list it.
public struct DisplayRow: Sendable {
	public let index: Int
	public let id: CGDirectDisplayID
	public let name: String?
	/// Global desktop points with a top-left origin at the main display, as window bounds use.
	public let bounds: CGRect
	/// The part of bounds left after the menu bar and Dock, in the same coordinates.
	public let visibleBounds: CGRect?
	public let scale: Double?
	public let pixelWidth: Int?
	public let pixelHeight: Int?
	public let rotation: Double
	public let isMain: Bool

	public var json: JSON {
		.object([
			"index": JSON(index),
			"display_id": JSON(id),
			"name": name.map(JSON.string),
			"bounds": DesktopMac.bounds(bounds),
			"visible_bounds": visibleBounds.map(DesktopMac.bounds),
			"scale": scale.map { JSON($0) },
			"pixel_width": pixelWidth.map { JSON($0) },
			"pixel_height": pixelHeight.map { JSON($0) },
			"rotation": JSON(rotation),
			"is_main": JSON(isMain),
		])
	}
}

/// A window on the screen capture's display, front to back.
public struct ScreenWindow: Sendable {
	public let pid: pid_t
	public let id: Int
	public let app: String?
	public let title: String?
	public let bounds: CGRect
	public let layer: Int
}

extension Mac {
	/// The active displays, main first, with AppKit's names and visible frames.
	public static func displayRows() async throws -> [DisplayRow] {
		var count: UInt32 = 0
		guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
			throw ToolError("DESKTOP_ERROR: No active displays are available..")
		}
		var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
		guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
			throw ToolError("DESKTOP_ERROR: The active display list is unavailable..")
		}
		let screens = await MainActor.run { () -> [CGDirectDisplayID: (name: String, visible: CGRect)] in
			var screens: [CGDirectDisplayID: (name: String, visible: CGRect)] = [:]
			for screen in NSScreen.screens {
				guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
				      screens[number.uint32Value] == nil
				else { continue }
				screens[number.uint32Value] = (screen.localizedName, screen.visibleFrame)
			}
			return screens
		}
		// AppKit frames are bottom-left at the primary display; flip them into window coordinates.
		let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
		return ids.prefix(Int(count)).enumerated().map { index, id in
			let mode = CGDisplayCopyDisplayMode(id)
			let scale = mode.flatMap { $0.width > 0 ? Double($0.pixelWidth) / Double($0.width) : nil }
			let visible = screens[id].map { screen in
				CGRect(x: screen.visible.minX, y: primaryHeight - screen.visible.maxY, width: screen.visible.width, height: screen.visible.height)
			}
			return DisplayRow(
				index: index, id: id, name: screens[id]?.name, bounds: CGDisplayBounds(id), visibleBounds: visible, scale: scale,
				pixelWidth: mode?.pixelWidth, pixelHeight: mode?.pixelHeight, rotation: CGDisplayRotation(id), isMain: CGDisplayIsMain(id) != 0
			)
		}
	}

	/// Windows on the normal, floating and panel levels that intersect the display, front to back.
	public static func screenWindows(on display: CGRect) -> [ScreenWindow] {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		let dock = Int(CGWindowLevelForKey(.dockWindow))
		let own = getpid()
		return list.compactMap { info in
			guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0, pid != own,
			      let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, id > 0,
			      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0, layer < dock,
			      (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
			      let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
			      bounds.width > 1, bounds.height > 1
			else { return nil }
			let overlap = bounds.intersection(display)
			guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
			let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
			return ScreenWindow(pid: pid, id: id, app: info[kCGWindowOwnerName as String] as? String, title: title, bounds: bounds, layer: layer)
		}
	}

	/// One whole display at one pixel per point, without the cursor, as Peekaboo's single-shot screen capture takes it.
	public static func captureDisplay(_ row: DisplayRow) async throws -> CGImage {
		// Peekaboo's capture gate checks the lock first; Node adds the final period after Peekaboo's own.
		if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
			throw ToolError("DESKTOP_ERROR: Capture failed: Screen capture is unavailable while the macOS GUI session is locked. `screen list` can still report connected displays; unlock the active user session and retry..")
		}
		guard CGPreflightScreenCaptureAccess() else {
			throw ToolError("permissionDenied: Screen Recording access is off for the Desktop Tools host.")
		}
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		guard let display = content.displays.first(where: { $0.displayID == row.id }) else {
			throw ToolError("DESKTOP_ERROR: The native capture did not confirm display \(row.index). Refresh the display list and try again..")
		}
		let config = SCStreamConfiguration()
		config.sourceRect = CGRect(origin: .zero, size: row.bounds.size)
		config.width = Int(row.bounds.width)
		config.height = Int(row.bounds.height)
		config.captureResolution = .best
		config.showsCursor = false
		return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
	}
}
