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

/// What one inspection asks for beyond the plain accessibility observation.
struct InspectRequest: Sendable {
	var pixels = false
	var ocr = false
	var scope: ScopeRequest?
	/// Whether the read may turn on a Chromium or Electron app's web accessibility.
	var web = true
}

/// An element ID from an earlier accessibility snapshot of the same window.
struct ScopeRequest: Sendable {
	let snapshot: String
	let element: String
}

private let maxScopedText = 64_000
private let maxRecognizedText = 64_000

extension Tools {
	static func inspect(_ arguments: JSON) async throws -> ToolResult {
		let started = ContinuousClock.now
		guard let pid = arguments["pid"]?.int.flatMap(Int32.init(exactly:)), pid > 0,
		      let windowID = arguments["window"]?.int, windowID > 0
		else { throw ToolError("Choose a positive application PID and window ID from the desktop inventory.") }
		let mode = arguments["mode"]?.string ?? "accessibility"
		guard mode == "accessibility" || mode == "pixels" else { throw ToolError("Choose accessibility or pixels inspection mode.") }
		var request = InspectRequest(pixels: mode == "pixels")
		if let ocr = arguments["ocr"] {
			guard let value = ocr.bool else { throw ToolError("Choose ocr true or false.") }
			request.ocr = value
		}
		if let scope = arguments["scope"] {
			request.scope = try scopeArgument(scope)
			if request.pixels { throw ToolError("A scope needs accessibility mode.") }
		}
		if let web = arguments["web_accessibility"] {
			guard let value = web.bool else { throw ToolError("Choose web_accessibility true or false.") }
			request.web = value
		}
		let save = try saveRequest(arguments)

		var retried = false
		let observed: Observation
		do {
			do {
				observed = try await observation(pid: pid, windowID: windowID, request, started: started)
			} catch let error as ToolError where !request.pixels && error.message.range(of: "incomplete|sparse", options: [.regularExpression, .caseInsensitive]) != nil {
				// A web view often fills in its tree within a second of a window appearing.
				try await Task.sleep(for: .seconds(1))
				retried = true
				observed = try await observation(pid: pid, windowID: windowID, request, started: started)
			}
		} catch let error as ToolError {
			let code = error.message.split(separator: ":").first.map(String.init) ?? "DESKTOP_ERROR"
			var target: [(String, JSON)] = [("pid", JSON(pid)), ("window_id", JSON(windowID)), ("mode", JSON(mode))]
			if let scope = request.scope { target.append(("scope", .object([("snapshot", JSON(scope.snapshot)), ("element", JSON(scope.element))]))) }
			return ToolResult(text: JSON.object([
				"inspection_error": .object([("code", JSON(code)), ("message", JSON(String(error.message.prefix(4000))))]),
				"retried": retried ? JSON(true) : JSON?.none,
				"requested_target": .object(target),
				"target_availability": await targetAvailability(pid: pid, windowID: windowID, message: error.message),
				"guidance": JSON(failureGuidance),
			]).text, isError: true)
		}
		var data = observed.data
		if let save {
			// After the observation, as in Node: a save that fails still leaves the snapshot published.
			data.set("saved", try self.save(observed.capture, area: observed.area, save))
		}
		let limit = (request.scope == nil ? maxText : maxScopedText) + (request.ocr ? maxRecognizedText : 0)
		return ToolResult(text: try boundedObservation(data, limit: limit), image: observed.image)
	}

	/// Node's validateScope: exactly a snapshot and an element ID, each without whitespace.
	static func scopeArgument(_ value: JSON) throws -> ScopeRequest {
		guard let keys = value.keys, keys.count == 2,
		      let snapshot = value["snapshot"]?.string, let element = value["element"]?.string,
		      [snapshot, element].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 256 && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil })
		else { throw ToolError("Choose scope as the snapshot_id and an element ID from an earlier desktop_inspect of this window.") }
		return ScopeRequest(snapshot: snapshot, element: element)
	}

	/// An observation bounded to the result limit, keeping the containers an agent can scope into.
	static func boundedObservation(_ data: JSON, limit: Int = maxText) throws -> String {
		// Elements entirely outside the window go first, since acting on them needs a scroll anyway (#178).
		let bounds = data["coordinate_context"]?["logical_bounds"]?.array
		let window = bounds.flatMap { pair -> CGRect? in
			guard pair.count == 2, let origin = pair[0].array, let size = pair[1].array, origin.count == 2, size.count == 2,
			      let x = origin[0].number, let y = origin[1].number, let width = size[0].number, let height = size[1].number
			else { return nil }
			return CGRect(x: x, y: y, width: width, height: height)
		}
		let offscreen: ((JSON) -> Bool)? = window.map { window in
			{ element in
				guard let frame = element["bounds"], let x = frame["x"]?.number, let y = frame["y"]?.number,
				      let width = frame["width"]?.number, let height = frame["height"]?.number
				else { return false }
				return !CGRect(x: x, y: y, width: width, height: height).intersects(window)
			}
		}
		return try bounded(data, field: "ui_elements", limit: limit, dropFirst: offscreen.map { ($0, "offscreen_omitted") }) { element in
			element["attributes"]?["role"]?.string.map(scopeRoles.contains) ?? false
		}
	}

	struct Observation: @unchecked Sendable {
		var data: JSON
		var image: (data: String, mimeType: String)
		/// The full-resolution capture, one pixel per point, and its extent in global desktop points.
		var capture: CGImage
		var area: CGRect
	}

	static func observation(pid: pid_t, windowID: Int) async throws -> (JSON, (data: String, mimeType: String)) {
		let observed = try await observation(pid: pid, windowID: windowID, InspectRequest(), started: .now)
		return (observed.data, observed.image)
	}

	/// One observation: the exact window's Accessibility tree and its pixels, read side by side, then checked
	/// against the window's identity so neither describes a different window.
	static func observation(pid: pid_t, windowID: Int, _ request: InspectRequest, started: ContinuousClock.Instant) async throws -> Observation {
		guard let generation = Mac.generation(pid) else {
			throw ToolError("DESKTOP_ERROR: Desktop observation target was not found: window id \(windowID) owned by PID \(pid).")
		}
		// The scope element comes from an earlier snapshot; read it before this observation publishes another.
		var source: ScopeSource?
		if let scope = request.scope { source = try await scopeSource(scope, pid: pid, windowID: windowID) }
		var budget = ElementBudget()
		if source != nil { (budget.maxDepth, budget.maxElements, budget.maxChildren, budget.seconds) = (64, 4000, 1000, 18) }
		budget.visibleFirst = true
		let accessibility = !request.pixels
		let ((window, image, elements, captureDone), web) = try await webRead(pid: pid, allowed: accessibility && request.web, tree: \.2) {
			try await read(pid: pid, windowID: windowID, generation: generation, budget: accessibility ? budget : nil, started: started)
		}
		let detectionDone = ContinuousClock.now
		let jpeg = try Mac.jpeg(image)
		let id = Snapshots.newID()
		await Snapshots.shared.put(Snapshot(
			id: id, pid: pid, generation: generation, windowID: windowID, windowBounds: window.bounds,
			imageSize: CGSize(width: jpeg.width, height: jpeg.height),
			elements: Dictionary(uniqueKeysWithValues: elements.elements.map { ($0.id, $0) }), focusedID: elements.focusedID,
			lastUsed: Date()
		))

		var listed: [Element]
		var scope: JSON?
		if let request = request.scope, let source {
			// Only the subtree is listed; its IDs still belong to this new snapshot, like every element it stored.
			let ordered = preorder(elements.elements)
			let position = try locateScope(source, in: ordered, generation: generation)
			listed = subtree(ordered, at: position)
			let root = ordered[position]
			scope = .object([
				("from_snapshot", JSON(request.snapshot)), ("from_element", JSON(request.element)), ("element", JSON(root.id)),
				("role", root.attributes["role"].map(JSON.string) ?? .null), ("label", root.label.map(JSON.string) ?? .null),
			])
		} else {
			// Grouped by type as Peekaboo returns them, with an open menu's items first.
			let grouped = elementTypeOrder.flatMap { type in elements.elements.filter { $0.type == type } }
			let isMenu = { (element: Element) in ["AXMenu", "AXMenuItem"].contains(element.attributes["role"] ?? "") }
			listed = grouped.filter(isMenu) + grouped.filter { !isMenu($0) }
		}
		let recognized: JSON? = request.ocr
			? await Mac.recognizeText(in: image, seconds: max(1, min(8, 26 - seconds(started.duration(to: .now)))))
			: JSON?.none
		let ms = { (from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> JSON in JSON((seconds(from.duration(to: to)) * 1000).rounded()) }
		let title = elements.windowTitle ?? window.title
		let display = Mac.displayIndex(window.bounds)
		let data: JSON = .object([
			"inspection_mode": accessibility ? "accessibility" : "pixels",
			"note": accessibility ? nil : "Pixel snapshot: no Accessibility elements or focused control. Its snapshot_id authorizes only screenshot-point clicks, point scrolls, and drags in this exact window; element, text, key, and insertion actions are refused.",
			"application_name": Mac.appName(pid).map(JSON.string),
			"window_title": JSON(title),
			"web_accessibility": web.map { JSON($0.change.rawValue) },
			"web_accessibility_via": web?.via.map { JSON($0.rawValue) },
			"snapshot_id": JSON(id),
			"element_count": JSON(source == nil ? elements.elements.count : listed.count),
			"scope": scope,
			"traversed_element_count": source.map { _ in JSON(elements.elements.count) },
			"offscreen_omitted": elements.offscreenSkipped > 0 ? JSON(elements.offscreenSkipped) : nil,
			"ui_elements": .array(listed.map(json)),
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
			"detection_metadata": accessibility ? .object([
				("element_count", JSON(elements.elements.count)),
				("warnings", .array(elements.warnings.map(JSON.string))),
			]) : JSON?.none,
			"recognized_text": recognized,
			"timings": .object([
				"capture_ms": ms(started, captureDone),
				"detection_ms": accessibility ? ms(started, detectionDone) : JSON?.none,
				"total_ms": ms(started, ContinuousClock.now),
			]),
			"target_receipt": .object([("pid", JSON(pid)), ("window_id", JSON(windowID)), ("process_start_identity_decimal", JSON(String(generation)))]),
			"image": .object([("width", JSON(jpeg.width)), ("height", JSON(jpeg.height)), ("note", JSON(imageNote))]),
		])
		return Observation(data: data, image: (jpeg.data.base64EncodedString(), "image/jpeg"), capture: image, area: window.bounds)
	}

	/// The window's pixels and, unless `budget` is nil for pixels mode, its Accessibility tree.
	private static func read(pid: pid_t, windowID: Int, generation: UInt64, budget: ElementBudget?, started: ContinuousClock.Instant) async throws
		-> ((pid: pid_t, bounds: CGRect, title: String), CGImage, ElementTree, ContinuousClock.Instant)
	{
		guard let window = Mac.window(windowID), window.pid == pid else {
			throw ToolError("DESKTOP_ERROR: Desktop observation target was not found: window id \(windowID) owned by PID \(pid).")
		}
		// The walk comes first: reading an element's children can make an app lay out more, as a SwiftUI list that
		// loads rows as they're read grows and moves what's below, so a screenshot taken during the walk can show
		// content where it no longer is, and a point read off it misses (#159).
		let elements = try await run { try budget.map { try Mac.elements(pid: pid, windowID: windowID, budget: $0) } ?? ElementTree() }
		let image = try await Mac.captureWindow(windowID, bounds: window.bounds)
		let captureDone = ContinuousClock.now
		guard Mac.generation(pid) == generation, let after = Mac.window(windowID), after.pid == pid, after.bounds == window.bounds else {
			throw ToolError("invalidRequest: Snapshot is stale: Exact observation window changed during the observation. Inspect it again.")
		}
		return (window, image, elements, captureDone)
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

	/// The target's app and window as listed after a failure, and why the window can't be observed; ported from
	/// Node's availability and failureAvailability.
	static func targetAvailability(pid: pid_t, windowID: Int, message: String) async -> JSON {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		var result: [(String, JSON)] = [("observed_at", JSON(formatter.string(from: Date())))]
		async let apps = try Mac.apps()
		async let windows = try Mac.windows(pid: pid)
		let appFields = ["pid", "is_active", "is_active_known", "is_hidden", "is_hidden_known", "process_start_identity_decimal"]
		let windowFields = [
			"window_id", "bounds", "is_on_screen", "is_minimized", "is_key", "space_ids", "display_index", "display_current_space_id",
			"display_asleep", "observation_capability", "observation_reason", "process_start_identity_decimal",
		]
		func listed(_ listing: JSON, field: String, key: String, id: Int, fields: [String]) -> (JSON, JSON?) {
			let item = listing[field]?.array?.first { $0[key]?.int == id }
			return (.object([
				("inventory_completeness", listing["inventory_completeness"] ?? .null),
				("target", item.map { item in .object(fields.compactMap { name in item[name].map { (name, $0) } }) } ?? .null),
			]), item)
		}
		do {
			result.append(("apps", listed(try await apps, field: "apps", key: "pid", id: Int(pid), fields: appFields).0))
		} catch {
			result.append(("apps", .object([("error", JSON(String("Error: \((error as? ToolError)?.message ?? "\(error)")".prefix(500))))])))
		}
		do {
			let listing = try await windows
			let (target, item) = listed(listing, field: "windows", key: "window_id", id: windowID, fields: windowFields)
			result.append(("windows", target))
			let locked = listing["session_locked"]?.bool == true
			let hidden = listing["app_hidden"]?.bool
			var availability: JSON
			if let item {
				availability = windowAvailability(item, sessionLocked: locked, appHidden: hidden)
				if availability["state"]?.string != "unavailable", message.range(of: "incomplete|sparse", options: [.regularExpression, .caseInsensitive]) != nil {
					availability = .object([("state", "limited"), ("reason", "sparse_accessibility"),
					                        ("hint", "The window is on screen on the current Space, but its Accessibility tree was incomplete, as often happens while a web view first loads. A page still loading may fill in after a few more seconds; otherwise inspect with mode pixels, adding ocr true to read its text.")])
				}
			} else if locked {
				availability = windowAvailability(.object([]), sessionLocked: true, appHidden: hidden)
			} else {
				availability = .object([("state", "unavailable"), ("reason", "window_gone"),
				                        ("hint", "The window is no longer in its app's window list; it may have closed. List desktop_windows again and choose a current window.")])
			}
			result.append(("availability", availability))
		} catch {
			result.append(("windows", .object([("error", JSON(String("Error: \((error as? ToolError)?.message ?? "\(error)")".prefix(500))))])))
		}
		return .object(result)
	}
}

/// Runs blocking Accessibility work on its own thread so it never holds a cooperative pool thread.
func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
	}
}
