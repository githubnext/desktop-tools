import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// The containers an agent can scope into, which a bounded result keeps over other elements.
private let scopeRoles: Set<String> = [
	"AXWindow", "AXSheet", "AXDrawer", "AXSplitGroup", "AXScrollArea", "AXOutline", "AXTable", "AXList", "AXBrowser",
	"AXTabGroup", "AXWebArea",
]

private let imageNote = "Screenshot, scaled down when large but never up; Accessibility bounds remain in their original coordinate system. Pointer points use fractions of this image: x from the left edge and y from the top, each >= 0 and < 1."

private let failureGuidance = "This inspection dispatched no input and returned no observation snapshot. target_availability.availability classifies the likely cause from a window listing read after the failure; follow its hint, but it can't prove the cause. Refresh desktop_apps and desktop_windows if the target changed. An incomplete Accessibility read was already retried once after a second when retried is true, so don't retry it at once; pixels mode can inspect the same exact window without Accessibility, with point-only action authority. Native capture already retries a changed capture receipt once. Neither mode activates a window. Do not loop on an unavailable target or repeat an earlier action to recover an observation."

extension Tools {
	static func inspect(_ arguments: JSON) async throws -> ToolResult {
		guard let pid = arguments["pid"]?.int.flatMap(Int32.init(exactly:)), pid > 0,
		      let windowID = arguments["window"]?.int, windowID > 0
		else { throw ToolError("Choose a positive application PID and window ID from the desktop inventory.") }
		let mode = arguments["mode"]?.string ?? "accessibility"
		guard mode == "accessibility" || mode == "pixels" else { throw ToolError("Choose accessibility or pixels inspection mode.") }
		for unsupported in ["ocr", "scope", "save_path", "region"] where arguments[unsupported] != nil {
			throw ToolError("desktop_inspect's \(unsupported) isn't in the Swift spike yet.")
		}
		guard mode == "accessibility" else { throw ToolError("desktop_inspect's pixels mode isn't in the Swift spike yet.") }

		var retried = false
		do {
			do {
				return try await observe(pid: pid, windowID: windowID)
			} catch let error as ToolError where error.message.range(of: "incomplete|sparse", options: [.regularExpression, .caseInsensitive]) != nil {
				// A web view often fills in its tree within a second of a window appearing.
				try await Task.sleep(for: .seconds(1))
				retried = true
				return try await observe(pid: pid, windowID: windowID)
			}
		} catch let error as ToolError {
			let code = error.message.split(separator: ":").first.map(String.init) ?? "DESKTOP_ERROR"
			return ToolResult(text: JSON.object([
				"inspection_error": .object([("code", JSON(code)), ("message", JSON(String(error.message.prefix(4000))))]),
				"retried": retried ? true : nil,
				"requested_target": .object([("pid", JSON(pid)), ("window_id", JSON(windowID)), ("mode", JSON(mode))]),
				"target_availability": await targetAvailability(pid: pid, windowID: windowID, message: error.message),
				"guidance": JSON(failureGuidance),
			]).text, isError: true)
		}
	}

	/// One observation: the exact window's Accessibility tree and its pixels, read side by side, then checked
	/// against the window's identity so neither describes a different window.
	static func observe(pid: pid_t, windowID: Int) async throws -> ToolResult {
		let started = ContinuousClock.now
		guard let generation = Mac.generation(pid) else {
			throw ToolError("notFound: Desktop observation target was not found: live process generation for PID \(pid).")
		}
		guard let window = Mac.window(windowID), window.pid == pid else {
			throw ToolError("notFound: Desktop observation target was not found: window id \(windowID) owned by PID \(pid).")
		}
		async let tree = run { try Mac.elements(pid: pid, windowID: windowID) }
		async let captured = Mac.captureWindow(windowID, bounds: window.bounds)
		let image = try await captured
		let captureDone = ContinuousClock.now
		let elements = try await tree
		let detectionDone = ContinuousClock.now
		guard Mac.generation(pid) == generation, let after = Mac.window(windowID), after.pid == pid, after.bounds == window.bounds else {
			throw ToolError("invalidRequest: Snapshot is stale: Exact observation window changed during the observation. Inspect it again.")
		}
		let jpeg = try Mac.jpeg(image)
		let id = Snapshots.newID()
		await Snapshots.shared.put(Snapshot(
			id: id, pid: pid, generation: generation, windowID: windowID, windowBounds: window.bounds,
			imageSize: CGSize(width: jpeg.width, height: jpeg.height),
			elements: Dictionary(uniqueKeysWithValues: elements.elements.map { ($0.id, $0) }), lastUsed: Date()
		))

		// Grouped by type as Peekaboo returns them, with an open menu's items first.
		let grouped = elementTypeOrder.flatMap { type in elements.elements.filter { $0.type == type } }
		let isMenu = { (element: Element) in ["AXMenu", "AXMenuItem"].contains(element.attributes["role"] ?? "") }
		let ordered = grouped.filter(isMenu) + grouped.filter { !isMenu($0) }
		let ms = { (from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> JSON in
			let d = from.duration(to: to)
			return JSON((Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded())
		}
		let title = elements.windowTitle ?? window.title
		let display = Mac.displayIndex(window.bounds)
		let data: JSON = .object([
			"inspection_mode": "accessibility",
			"application_name": Mac.appName(pid).map(JSON.string),
			"window_title": JSON(title),
			"snapshot_id": JSON(id),
			"element_count": JSON(elements.elements.count),
			"ui_elements": .array(ordered.map(json)),
			"coordinate_context": .object([
				("version", 1),
				("logical_space", "global_display_points"),
				("origin", "top_left"),
				("logical_bounds", [[JSON(Double(window.bounds.minX)), JSON(Double(window.bounds.minY))], [JSON(Double(window.bounds.width)), JSON(Double(window.bounds.height))]]),
				("delivered_image_size", [JSON(image.width), JSON(image.height)]),
				("native_scale", JSON(Mac.backingScale(window.bounds))),
				("requested_scale", .object([("logical1x", .object([]))])),
				("output_scale", 1),
				("display", display.map { .object([("index", JSON($0))]) } ?? .null),
				("window", .object([("title", JSON(title)), ("window_id", JSON(windowID)), ("index", 0)])),
			]),
			"detection_metadata": .object([
				("element_count", JSON(elements.elements.count)),
				("warnings", .array(elements.warnings.map(JSON.string))),
			]),
			"timings": .object([
				("capture_ms", ms(started, captureDone)),
				("detection_ms", ms(started, detectionDone)),
				("total_ms", ms(started, ContinuousClock.now)),
			]),
			"target_receipt": .object([("pid", JSON(pid)), ("window_id", JSON(windowID)), ("process_start_identity_decimal", JSON(String(generation)))]),
			"image": .object([("width", JSON(jpeg.width)), ("height", JSON(jpeg.height)), ("note", JSON(imageNote))]),
		])
		let text = try bounded(data, field: "ui_elements") { element in
			element["attributes"]?["role"]?.string.map(scopeRoles.contains) ?? false
		}
		return ToolResult(text: text, image: (jpeg.data.base64EncodedString(), "image/jpeg"))
	}

	/// The element actions an agent can request; AXPress stays with desktop_click, which performs it with its checks.
	static let elementActions: Set<String> = [
		"AXShowMenu", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel", "AXPick", "AXRaise", "AXScrollToVisible",
	]

	static func json(_ element: Element) -> JSON {
		var attributes = element.attributes
		// Report only the actions an agent can request, keeping each element's result small.
		if let listed = attributes["actions"] {
			let offered = listed.split(separator: ",").filter { elementActions.contains(String($0)) }
			attributes["actions"] = offered.isEmpty ? nil : offered.joined(separator: ",")
		}
		return .object([
			"id": JSON(element.id),
			"role": JSON(element.type),
			"label": element.label.map(JSON.string),
			"value": element.value.map(JSON.string),
			"bounds": .object([("x", JSON(Double(element.frame.minX))), ("y", JSON(Double(element.frame.minY))), ("width", JSON(Double(element.frame.width))), ("height", JSON(Double(element.frame.height)))]),
			"is_enabled": JSON(element.isEnabled),
			"is_selected": element.isSelected.map(JSON.bool),
			"attributes": .object(attributes.sorted { $0.key < $1.key }.map { ($0.key, JSON($0.value)) }),
		])
	}

	/// Why the window can't be observed, from a listing read after the failure; ported from failureAvailability.
	static func targetAvailability(pid: pid_t, windowID: Int, message: String) async -> JSON {
		guard let listing = try? await Mac.windows(pid: pid) else {
			return .object([("availability", .object([("state", "unavailable"), ("reason", "window_gone"),
			                                           ("hint", "The window is no longer in its app's window list; it may have closed. List desktop_windows again and choose a current window.")]))])
		}
		let locked = listing["session_locked"]?.bool == true
		let hidden = listing["app_hidden"]?.bool
		guard let row = listing["windows"]?.array?.first(where: { $0["window_id"]?.int == windowID }) else {
			if locked { return .object([("availability", windowAvailability(.object([]), sessionLocked: true, appHidden: hidden))]) }
			return .object([("availability", .object([("state", "unavailable"), ("reason", "window_gone"),
			                                           ("hint", "The window is no longer in its app's window list; it may have closed. List desktop_windows again and choose a current window.")]))])
		}
		var availability = windowAvailability(row, sessionLocked: locked, appHidden: hidden)
		if availability["state"]?.string != "unavailable", message.range(of: "incomplete|sparse", options: [.regularExpression, .caseInsensitive]) != nil {
			availability = .object([("state", "limited"), ("reason", "sparse_accessibility"),
			                        ("hint", "The window is on screen on the current Space, but its Accessibility tree was incomplete, as often happens while a web view first loads. A page still loading may fill in after a few more seconds; otherwise inspect with mode pixels, adding ocr true to read its text.")])
		}
		return .object([("availability", availability)])
	}
}

/// Runs blocking Accessibility work on its own thread so it never holds a cooperative pool thread.
func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
	}
}
