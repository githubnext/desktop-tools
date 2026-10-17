import AppKit
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

private struct Display: Encodable {
	let index: Int
	let display_id: UInt32
	let name: String?
	/// Global desktop points with a top-left origin at the main display, as window bounds use.
	let bounds: Bounds
	let scale: Double?
	let is_main: Bool
}

private struct ScreenWindow: Encodable {
	let pid: Int32
	let window_id: Int
	let app_name: String?
	let title: String?
	let bounds: Bounds
	let layer: Int
	let process_start_identity_decimal: String?
	let observation_capability: String?
	let target: ManagementTarget?
}

private struct Screen: Encodable {
	let display: Display
	let displays: [Display]
	let windows: [ScreenWindow]
	let window_order = "front_to_back"
	let windows_note = "Windows on the normal, floating and panel levels that intersect this display when the screenshot was taken, front to back. Bounds are global desktop points. Pass pid and window_id to desktop_inspect to act on one; target is the desktop_windows target object when native inventory matched it."
	let warnings: [String]
	let coordinate_context: CaptureCoordinateContext
	let capture_warning: String?
	let diagnostics: DesktopObservationDiagnostics
	let timings: ObservationTimings
}

private struct ScreenReply: Encodable {
	let success = true
	let data: Screen
}

private struct ScreenError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

private func activeDisplays() throws -> [Display] {
	var count: UInt32 = 0
	guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
		throw ScreenError("No active displays are available.")
	}
	var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
	guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
		throw ScreenError("The active display list is unavailable.")
	}
	let names = Dictionary(
		NSScreen.screens.compactMap { screen -> (UInt32, String)? in
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			else { return nil }
			return (number.uint32Value, screen.localizedName)
		},
		uniquingKeysWith: { first, _ in first }
	)
	// CoreGraphics lists the main display first, so index 0 is the main display.
	return ids.prefix(Int(count)).enumerated().map { index, id in
		let mode = CGDisplayCopyDisplayMode(id)
		let scale = mode.flatMap { $0.width > 0 ? Double($0.pixelWidth) / Double($0.width) : nil }
		return Display(
			index: index, display_id: id, name: names[id], bounds: Bounds(CGDisplayBounds(id)),
			scale: scale, is_main: CGDisplayIsMain(id) != 0
		)
	}
}

/// Matches a capture's display bounds in global top-left points or, from the legacy engine, Cocoa's bottom-left points.
private func sameDisplay(_ captured: CGRect, _ display: Display) -> Bool {
	let main = CGDisplayBounds(CGMainDisplayID())
	let bounds = display.bounds
	let flipped = main.height - (bounds.y + bounds.height)
	return abs(captured.width - bounds.width) < 1 && abs(captured.height - bounds.height) < 1
		&& abs(captured.minX - bounds.x) < 1
		&& (abs(captured.minY - bounds.y) < 1 || abs(captured.minY - flipped) < 1)
}

private func visibleWindows(on display: Display) -> [(pid: Int32, id: Int, app: String?, title: String?, bounds: CGRect, layer: Int)] {
	let area = CGRect(x: display.bounds.x, y: display.bounds.y, width: display.bounds.width, height: display.bounds.height)
	let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
		as? [[String: Any]] ?? []
	let dock = Int(CGWindowLevelForKey(.dockWindow))
	let own = getpid()
	return list.compactMap { info in
		guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0, pid != own,
			let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, id > 0,
			let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0, layer < dock,
			(info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
			let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
			bounds.width > 1, bounds.height > 1, !bounds.intersection(area).isNull,
			bounds.intersection(area).width > 0, bounds.intersection(area).height > 0
		else { return nil }
		let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
		return (pid, id, info[kCGWindowOwnerName as String] as? String, title, bounds, layer)
	}
}

/// Captures one whole display without element detection or an input snapshot.
func nativeScreen(_ client: PeekabooBridgeClient, path: String, index requested: Int?) async throws -> Data {
	let displays = try activeDisplays()
	let wanted = requested ?? 0
	guard displays.indices.contains(wanted) else {
		throw ScreenError("Display \(wanted) is not active. Choose an index from 0 to \(displays.count - 1).")
	}
	let display = displays[wanted]
	// Peekaboo indexes its capture engine's own display list; confirm the captured display by its bounds.
	var order = [wanted]
	order += displays.indices.filter { $0 != wanted }
	var observed: DesktopObservationResult?
	for candidate in order {
		try Task.checkCancellation()
		let observation = try await client.desktopObservationWithOutcome(.init(
			target: .screen(index: candidate),
			capture: .init(scale: .logical1x, focus: .background),
			detection: .init(mode: .none),
			output: .init(saveSnapshot: false, includeImageData: true),
			timeout: .init(overall: 20)
		))
		let result = observation.payload
		guard case .screen = result.target.kind, result.elements == nil, result.files.publishedSnapshotID == nil
		else { throw ScreenError("The native observation did not return a screen-only capture.") }
		if let info = result.capture.metadata.displayInfo, sameDisplay(info.bounds, display) {
			observed = result
			break
		}
	}
	guard let result = observed else {
		throw ScreenError("The native capture did not confirm display \(wanted). Refresh the display list and try again.")
	}
	let image = try result.verifiedCaptureImageData(requirement: .requireDigest)
	guard !image.isEmpty, image.count <= 32 * 1024 * 1024 else {
		throw ScreenError("The native observation returned an empty or oversized screenshot.")
	}
	try image.write(to: URL(fileURLWithPath: path), options: [.atomic])

	let found = visibleWindows(on: display)
	var warnings: [String] = []
	// Native inventory supplies process generations, Accessibility titles and exact targets for these windows.
	var inventory: [Int: ServiceWindowInfo] = [:]
	var seen = Set<Int32>()
	for pid in found.map(\.pid) where seen.insert(pid).inserted {
		try Task.checkCancellation()
		guard seen.count <= 32 else {
			warnings.append("Native window inventory was read for the first 32 applications only.")
			break
		}
		do {
			let windows = try await client.listWindowMutationInventory(target: .application("PID:\(pid)"))
			for window in windows.items where window.mutationIdentity?.ownerProcessIdentifier ?? pid == pid {
				inventory[window.windowID] = window
			}
		} catch {
			try Task.checkCancellation()
			warnings.append("Native window inventory was unavailable for PID \(pid).")
		}
	}
	let windows = found.map { window in
		let native = inventory[window.id]
		let title = native.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? window.title
		return ScreenWindow(
			pid: window.pid,
			window_id: window.id,
			app_name: window.app,
			title: title,
			bounds: Bounds(window.bounds),
			layer: window.layer,
			process_start_identity_decimal: native?.mutationIdentity.map { String($0.ownerProcessStartIdentity) },
			observation_capability: native?.observationCapability?.mode.rawValue,
			target: native.flatMap { ManagementTarget(window: $0, pid: window.pid) }
		)
	}
	return try JSONEncoder().encode(ScreenReply(data: Screen(
		display: display,
		displays: displays,
		windows: windows,
		warnings: warnings,
		coordinate_context: CaptureCoordinateContext(metadata: result.capture.metadata),
		capture_warning: result.capture.warning,
		diagnostics: result.diagnostics,
		timings: result.timings
	)))
}
