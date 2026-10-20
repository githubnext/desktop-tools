import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_screen, ported from Node's screen() in src/client.ts and the native client's screen.swift.

private let windowsNote = "Windows on the normal, floating and panel levels that intersect this display when the screenshot was taken, front to back. Bounds are global desktop points. Pass pid and window_id to desktop_inspect to act on one; target is the desktop_windows target object when native inventory matched it."
private let recognizedNote = "Recognized from pixels, not read from any app: text can be misread, merged or missed, and is not ground truth. box is a fraction of the screenshot from its top-left corner; bounds are global desktop points. This capture has no snapshot, so no input can target these; pass the window under the text to desktop_inspect."
private let screenImageNote = "Whole-display screenshot, scaled down when large but never up. Observation only: there is no snapshot_id and no input can target this image. Window and display bounds are global desktop points; pass a window's pid and window_id to desktop_inspect to act on it."
/// Native window inventory is read for this many applications at most.
private let maxInventoryApps = 32
private let maxRecognized = 64_000

extension Tools {
	static func screen(_ arguments: JSON) async throws -> ToolResult {
		let started = ContinuousClock.now
		var wanted = 0
		if let value = arguments["display"] {
			guard let index = value.int, (0...63).contains(index) else {
				throw ToolError("Choose a display index from 0 to 63 from the returned displays list.")
			}
			wanted = index
		}
		var ocr = false
		if let value = arguments["ocr"] {
			guard let flag = value.bool else { throw ToolError("Choose ocr true or false.") }
			ocr = flag
		}
		let save = try saveRequest(arguments)

		let displays = try await Mac.displayRows()
		guard displays.indices.contains(wanted) else {
			throw ToolError("DESKTOP_ERROR: Display \(wanted) is not active. Choose an index from 0 to \(displays.count - 1)..")
		}
		let display = displays[wanted]
		let image = try await Mac.captureDisplay(display)
		let captureDone = ContinuousClock.now

		// Recognition and the window inventory don't depend on each other.
		async let recognition: JSON? = ocr
			? Mac.recognizeText(in: image, display: display.bounds, seconds: max(1, min(8, 26 - seconds(started.duration(to: .now)))))
			: nil
		let (windows, warnings) = await screenWindows(on: display.bounds)
		var recognized = await recognition
		recognized?.set("note", JSON(recognizedNote))
		if let text = recognized?.text, text.utf8.count > maxRecognized {
			recognized = .object([("error", "Recognized text was missing or exceeded its result limit.")])
		}

		let ms = { (from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> JSON in JSON((seconds(from.duration(to: to)) * 1000).rounded()) }
		var data: JSON = .object([
			"display": display.json,
			"displays": .array(displays.map(\.json)),
			"windows": .array(windows),
			"window_order": "front_to_back",
			"windows_note": JSON(windowsNote),
			"warnings": .array(warnings.map(JSON.string)),
			"recognized_text": recognized,
			"coordinate_context": .object([
				("version", 1),
				("logical_space", "global_display_points"),
				("origin", "top_left"),
				("logical_bounds", [[JSON(Double(display.bounds.minX)), JSON(Double(display.bounds.minY))], [JSON(Double(display.bounds.width)), JSON(Double(display.bounds.height))]]),
				("delivered_image_size", [JSON(image.width), JSON(image.height)]),
				("requested_scale", .object([("logical1x", .object([]))])),
				("native_scale", display.scale.map { JSON($0) } ?? .null),
				("output_scale", 1),
				("display", .object([("index", JSON(display.index)), ("name", JSON(String(display.id)))])),
			]),
			"timings": .object([
				"capture_ms": ms(started, captureDone),
				"total_ms": ms(started, ContinuousClock.now),
			]),
		])
		if let save { data.set("saved", try self.save(image, area: display.bounds, save)) }
		let jpeg = try Mac.jpeg(image)
		data.set("image", .object([("width", JSON(jpeg.width)), ("height", JSON(jpeg.height)), ("note", JSON(screenImageNote))]))
		let text = try bounded(data, field: "windows", limit: maxText + (ocr ? maxRecognized : 0))
		return ToolResult(text: text, image: (jpeg.data.base64EncodedString(), "image/jpeg"))
	}

	/// The display's windows with each one's desktop_windows target, read concurrently per app for the first 32 apps.
	private static func screenWindows(on display: CGRect) async -> ([JSON], [String]) {
		let found = Mac.screenWindows(on: display)
		var pids: [pid_t] = []
		var capped = false
		for pid in found.map(\.pid) where !pids.contains(pid) {
			guard pids.count < maxInventoryApps else { capped = true; break }
			pids.append(pid)
		}
		let inventories = await withTaskGroup(of: (pid_t, JSON?).self) { group in
			for pid in pids { group.addTask { (pid, try? await Mac.windows(pid: pid)) } }
			var listed: [pid_t: JSON?] = [:]
			for await (pid, listing) in group { listed[pid] = listing }
			return listed
		}
		var rows: [Int: JSON] = [:]
		var warnings: [String] = []
		for pid in pids {
			guard let listing = inventories[pid] ?? nil else {
				warnings.append("Native window inventory was unavailable for PID \(pid).")
				continue
			}
			for row in listing["windows"]?.array ?? [] {
				if let id = row["window_id"]?.int { rows[id] = row }
			}
		}
		let windows: [JSON] = found.map { window in
			let native = rows[window.id].flatMap { $0["target"]?["pid"]?.int == Int(window.pid) ? $0 : nil }
			let title = native?["window_title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? window.title
			return .object([
				"pid": JSON(window.pid),
				"window_id": JSON(window.id),
				"app_name": window.app.map(JSON.string),
				"title": title.map(JSON.string),
				"bounds": .object([("x", JSON(Double(window.bounds.minX))), ("y", JSON(Double(window.bounds.minY))), ("width", JSON(Double(window.bounds.width))), ("height", JSON(Double(window.bounds.height)))]),
				"layer": JSON(window.layer),
				"process_start_identity_decimal": native?["process_start_identity_decimal"],
				"observation_capability": native?["observation_capability"],
				"target": native?["target"],
			])
		}
		if capped { warnings.append("Native window inventory was read for the first 32 applications only.") }
		return (windows, warnings)
	}
}
