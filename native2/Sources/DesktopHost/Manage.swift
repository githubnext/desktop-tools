import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// App and window management: the Node server's checks and follow-up observation (validateManagement,
// observeManagement, managementResult in src/client.ts) around the native client's management and launch
// results (native/Sources/client), with the work itself in DesktopMac/Manage.swift.

private let launchUncertain = "The app may still open later. Observe desktop_apps before any further action; do not blindly repeat the launch."
private let openUncertain = "The item may still open later. Observe desktop_apps before any further action; do not blindly repeat the open."
private let completedObservationError = "The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly."

/// A Node server check that fails, which it reports as a refused action.
private func invalid(_ message: String) -> ToolError { ToolError(message) }

private func isInteger(_ value: JSON?, in range: ClosedRange<Double>) -> Bool {
	guard let n = value?.number else { return false }
	return n.rounded() == n && range.contains(n)
}

private func finite(_ value: JSON?) -> Double? {
	guard let n = value?.number, n.isFinite else { return nil }
	return n
}

extension Tools {
	static let manageOps: [String: String] = [
		"desktop_activate": "activate", "desktop_hide": "hide", "desktop_unhide": "unhide", "desktop_quit": "quit",
		"desktop_close": "close", "desktop_focus": "focus", "desktop_minimize": "minimize", "desktop_restore": "restore",
		"desktop_maximize": "maximize", "desktop_fullscreen": "fullscreen", "desktop_move": "move", "desktop_resize": "resize",
	]

	// MARK: Node's checks

	/// validateAppTarget: a pid and a decimal process generation that fits 64 bits.
	private static func appTarget(_ target: JSON?) throws -> (pid: pid_t, generation: UInt64) {
		guard let target, target.pairs != nil, isInteger(target["pid"], in: 1...2_147_483_647),
		      let identity = target["process_start_identity_decimal"]?.string,
		      identity.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil,
		      let generation = UInt64(identity)
		else { throw invalid("Pass the application's target object from fresh desktop inventory unchanged.") }
		return (pid_t(target["pid"]!.number!), generation)
	}

	private static func appOnly(_ target: JSON?) throws -> (pid: pid_t, generation: UInt64) {
		let app = try appTarget(target)
		guard target?.keys?.allSatisfy({ ["pid", "process_start_identity_decimal"].contains($0) }) == true else {
			throw invalid("Pass only the application's target object from desktop_apps.")
		}
		return app
	}

	private static func windowTarget(_ target: JSON?) throws -> ExactWindow {
		let app = try appTarget(target)
		let bounds = target?["bounds"]
		guard isInteger(target?["window_id"], in: 1...4_294_967_295), let minimized = target?["is_minimized"]?.bool,
		      let x = finite(bounds?["x"]), let y = finite(bounds?["y"]),
		      let width = finite(bounds?["width"]), let height = finite(bounds?["height"]), width > 0, height > 0
		else { throw invalid("Pass the window's target object, including its original bounds, from desktop_windows unchanged.") }
		return ExactWindow(pid: app.pid, generation: app.generation, id: target!["window_id"]!.int!,
		                   bounds: CGRect(x: x, y: y, width: width, height: height), isMinimized: minimized)
	}

	/// validateApplication, which the Node server applies to launch and to open's optional application.
	private static func application(_ value: JSON?) throws -> (path: String?, bundleID: String?) {
		guard let value, let keys = value.keys, keys.count == 1 else { throw invalid("Use exactly one application path or bundle_id.") }
		if keys[0] == "path" {
			guard let path = value["path"]?.string, path.utf16.count <= 4096, path.hasPrefix("/"),
			      path.lowercased().hasSuffix(".app"), !path.contains("\0")
			else { throw invalid("Use an absolute .app path for launch.") }
			return (path, nil)
		}
		guard keys[0] == "bundle_id", let id = value["bundle_id"]?.string, id.utf16.count <= 256,
		      id.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
		else { throw invalid("Use an exact application bundle ID for launch.") }
		return (nil, id)
	}

	// MARK: Management

	/// One app or window management tool: the Node server's checks, then the native client's checks and
	/// result, then the Node server's routing and follow-up observation.
	static func manage(_ name: String, _ arguments: JSON) async throws -> ToolResult {
		let op = manageOps[name]!
		let appLevel = ["activate", "quit", "hide", "unhide"].contains(op)
		var app: (pid: pid_t, generation: UInt64)
		var window: ExactWindow?
		var force = false
		if appLevel {
			app = try appOnly(arguments["target"])
			if op == "quit", let value = arguments["force"] {
				guard let flag = value.bool else { throw invalid("Quit force must be true or false.") }
				force = flag
			}
		} else {
			let target = try windowTarget(arguments["target"])
			window = target
			app = (target.pid, target.generation)
		}
		var enabled = false
		var position = CGPoint.zero
		var size = CGSize.zero
		if op == "fullscreen" {
			guard let flag = arguments["enabled"]?.bool else { throw invalid("Full screen enabled must be true to enter or false to exit.") }
			enabled = flag
		}
		if op == "move" {
			guard let x = finite(arguments["position"]?["x"]), let y = finite(arguments["position"]?["y"]) else {
				throw invalid("Window position must contain finite x and y in desktop logical points.")
			}
			position = CGPoint(x: x, y: y)
		}
		if op == "resize" {
			guard let width = finite(arguments["size"]?["width"]), let height = finite(arguments["size"]?["height"]), width > 0, height > 0 else {
				throw invalid("Window size must contain positive finite width and height in desktop logical points.")
			}
			size = CGSize(width: width, height: height)
		}

		var fields: [(String, JSON?)] = []
		var outcome = "refused"
		var native: JSON?
		var terminated: Bool?
		var space: (id: UInt64, kind: String)?
		var message: String?
		var fresh = false
		var error: JSON?
		var receipt: JSON?
		let receiptJSON = JSON.object([
			"pid": JSON(app.pid), "window_id": window.map { JSON($0.id) },
			"process_start_identity_decimal": JSON(String(app.generation)),
		])
		var serviced = false
		do {
			if Mac.sessionLocked {
				throw ManageFailure.lockedManagement
			}
			guard Mac.applicationMatches(pid: app.pid, generation: app.generation) else {
				throw ToolError("The observed application generation could not be verified. Refresh desktop_apps before acting.")
			}
			if let window, !Mac.windowTargetHolds(window) {
				throw ManageFailure.pinnedChanged
			}
			let pinned = app
			serviced = true
			let result: (outcome: JSON, terminated: Bool?) = try await run { [window, force, enabled, position, size] () throws -> (JSON, Bool?) in
				switch op {
				case "activate", "unhide":
					// macOS has no background unhide; activation is the exact route that unhides an app.
					return (try Mac.activate(pid: pinned.pid, generation: pinned.generation), nil)
				case "hide": return (try Mac.hide(pid: pinned.pid, generation: pinned.generation), nil)
				case "quit":
					let quit = try Mac.quit(pid: pinned.pid, generation: pinned.generation, force: force)
					return (quit.outcome, quit.terminated)
				case "close": return (try Mac.closeWindow(window!), nil)
				case "focus": return (try Mac.focusWindow(window!), nil)
				case "minimize": return (try Mac.minimizeWindow(window!), nil)
				case "restore": return (try Mac.restoreWindow(window!), nil)
				case "maximize": return (try Mac.maximizeWindow(window!), nil)
				case "fullscreen": return (try Mac.setFullScreen(window!, enabled), nil)
				case "move": return (try Mac.moveWindow(window!, to: position), nil)
				default: return (try Mac.resizeWindow(window!, to: size), nil)
				}
			}
			native = result.outcome
			terminated = result.terminated
			receipt = receiptJSON
			let state = result.outcome["state"]?.string
			fresh = result.outcome["dispatch_state"]?.string == "dispatched"
			if op == "fullscreen", let window { space = Mac.windowSpace(window.id) }
			if terminated == false {
				message = force
					? "The force quit was sent, but termination was not confirmed. Refresh desktop_apps before any further action; do not blindly repeat it."
					: "The normal quit request was accepted, but termination was not confirmed. Inspect remaining windows for unsaved work or other dialogs with desktop_dialog; do not blindly retry, and force quit only deliberately because it discards unsaved work."
			}
			let confirmed = state == "confirmed_change" || state == "confirmed_no_change"
			if op == "close", !confirmed {
				message = "The close request was not confirmed complete. Inspect remaining windows for unsaved work or other dialogs; do not blindly retry close."
			}
			outcome = switch state {
			case "refused": "refused"
			case "indeterminate", "partial": "unknown"
			default: result.outcome["evidence"]?.string == "operation_still_running" || terminated == false || (op == "close" && !confirmed) ? "unknown" : "completed"
			}
		} catch let failure as ManageFailure {
			outcome = failure.dispatched ? "unknown" : "refused"
			native = failure.outcome
			// The Bridge attributes a close failure to the window only once its pinned target checked out.
			if op == "close", serviced { receipt = receiptJSON }
			fresh = failure.dispatched || failure.refreshTarget
			error = .object([
				"code": "DESKTOP_ACTION_FAILED", "message": JSON(failure.message), "hint": failure.hint.map(JSON.string),
				"cause": failure.cause.map(JSON.string),
			])
		} catch let thrown {
			let invoked = !(thrown is ToolError)
			outcome = invoked ? "unknown" : "refused"
			fresh = invoked
			error = .object([
				"code": "DESKTOP_ACTION_FAILED", "message": JSON((thrown as? ToolError)?.message ?? String(describing: thrown)),
				"hint": invoked ? Optional(JSON("Refresh the target before any retry; the action may already have happened.")) : nil,
			])
		}
		fields = [
			("outcome", JSON(outcome)), ("action", JSON(op)), ("native_outcome", native), ("terminated", terminated.map(JSON.bool)),
			("space_id", space.map { JSON($0.id) }), ("space_kind", space.map { JSON($0.kind) }), ("message", message.map(JSON.string)),
			("requires_fresh_observation", JSON(fresh)), ("error", error), ("target_receipt", receipt),
		]
		let data = JSON.object(fields.compactMap { key, value in value.map { (key, $0) } })
		return await routed(op, data: data, target: arguments["target"] ?? .null, window: window?.id)
	}

	/// The Node server's routing of a native action result: refusals explained, uncertain closes and quits
	/// observed, other uncertainty returned as is, and completed actions observed.
	private static func routed(_ op: String, data: JSON, target: JSON, window: Int?) async -> ToolResult {
		let outcome = data["outcome"]?.string ?? "refused"
		if outcome == "unknown", (op == "quit" && data["terminated"]?.bool == false) || (op == "close" && data["target_receipt"] != nil) {
			return await observeManagement(op, action: data, target: target, window: window)
		}
		if outcome == "refused" { return await explainRefusal(data) }
		if outcome != "completed" { return actionResult(data, outcome) }
		return await observeManagement(op, action: data, target: target, window: window)
	}

	/// explainRefusal: a refusal names its window's availability when that explains it.
	private static func explainRefusal(_ data: JSON) async -> ToolResult {
		var data = data
		if let receipt = data["target_receipt"], let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)), let window = receipt["window_id"]?.int {
			let availability = await targetAvailability(pid: pid, windowID: window, message: data["error"]?["message"]?.string ?? "")
			if let state = availability["availability"], state["state"]?.string != "available" {
				data.set("target_availability", state)
			}
		}
		return actionResult(data, "refused")
	}

	private static func actionResult(_ data: JSON, _ outcome: String) -> ToolResult {
		var text = JSON.object([("action", data)]).text
		if text.utf8.count > maxText {
			text = JSON.object([
				"action": .object([
					"outcome": JSON(outcome), "target_receipt": data["target_receipt"], "terminated": data["terminated"],
					"created_windows": data["created_windows"],
				]),
				"warning": "Native action metadata exceeded the result limit. Inspect the current state.",
			]).text
		}
		return ToolResult(text: text, outcome: outcome, isError: outcome != "completed")
	}

	/// observeManagement: the refreshed app and window inventory after the action, and a fresh inspection of a
	/// window the action left in place.
	private static func observeManagement(_ op: String, action: JSON, target: JSON, window: Int?) async -> ToolResult {
		var data: JSON = .object([("action", action)])
		let outcome = action["outcome"]?.string == "unknown" ? "unknown" : "completed"
		let applicationLevel = ["activate", "quit", "hide", "unhide", "launch", "open"].contains(op)
		guard let receipt = action["target_receipt"], let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)),
		      receipt["pid"] == target["pid"],
		      receipt["process_start_identity_decimal"] == target["process_start_identity_decimal"],
		      applicationLevel ? receipt["window_id"] == nil : receipt["window_id"]?.int == window
		else {
			var changed = action
			changed.set("outcome", "unknown")
			changed.set("reason", "The native action returned a different target receipt. Refresh the target before any retry.")
			return actionResult(changed, "unknown")
		}
		let identity = receipt["process_start_identity_decimal"]
		do {
			let apps = try await Mac.apps()
			guard let rows = apps["apps"]?.array else { throw ToolError("Native application inventory is unavailable.") }
			data.set("application_inventory_completeness", apps["inventory_completeness"])
			data.set("application_inventory_warnings", apps["inventory_warnings"])
			let app = rows.first { $0["pid"]?.int == Int(pid) }
			data.set("application", app ?? .null)
			// The native receipt owns close and quit evidence; later inventory can't undo or establish it.
			if app == nil, op == "quit" || op == "close" { return managementResult(data, action: action, outcome: outcome) }
			guard let app else { throw ToolError("The target application was not returned by the later inventory.") }
			guard app["process_start_identity_decimal"] == identity else {
				throw ToolError("The application changed process generation after the action.")
			}
			let windows = try await Mac.windows(pid: pid)
			guard let list = windows["windows"]?.array else { throw ToolError("Native window inventory is unavailable.") }
			data.set("window_inventory_completeness", windows["inventory_completeness"])
			data.set("window_inventory_warnings", windows["inventory_warnings"])
			let locked = windows["session_locked"]?.bool == true
			let hidden = windows["app_hidden"]?.bool
			let windowRows = list.map { row in
				var row = row
				row.set("availability", windowAvailability(row, sessionLocked: locked, appHidden: hidden))
				return row
			}
			data.set("windows", .array(windowRows))
			if list.contains(where: { $0["process_start_identity_decimal"] != identity }) {
				throw ToolError("Later window inventory could not be bound to the original application generation.")
			}
			if applicationLevel || op == "close" { return managementResult(data, action: action, outcome: outcome) }
			guard let row = windowRows.first(where: { $0["window_id"]?.int == window }) else {
				throw ToolError("The exact window was not returned by the later inventory.")
			}
			// A window action returns only that window's refreshed row, whose target the next call takes. Input needs a
			// new snapshot, so the agent inspects next instead of paying for an inspection attached here.
			data.set("windows", nil)
			data.set("window", row)
			return managementResult(data, action: action)
		} catch {
			data.set("observation_error", JSON((error as? ToolError)?.message ?? String(describing: error)))
			data.set("message", JSON(outcome == "completed" ? completedObservationError
					: "Native completion was not confirmed and later inventory was unavailable. Refresh the target before choosing any further action; do not blindly repeat the request."))
			return managementResult(data, action: action, outcome: outcome)
		}
	}

	private static func managementResult(_ data: JSON, action: JSON, outcome: String = "completed") -> ToolResult {
		if let text = try? (data["windows"] != nil ? bounded(data, field: "windows") : data.text), text.utf8.count <= maxText {
			return ToolResult(text: text, outcome: outcome, isError: outcome != "completed")
		}
		var preserved = action
		preserved.set("observation_error", data["observation_error"] ?? "The later inventory exceeds the result limit.")
		preserved.set("message", "The native action outcome is preserved. Later inventory was omitted to fit the result limit; refresh the target without blindly repeating the action.")
		return actionResult(preserved, outcome)
	}

	// MARK: Launch and open

	/// desktop_launch and desktop_open: the Node server's checks, the native client's stricter ones, then the
	/// launch with the windows it created, observed like any other app-level action.
	static func launch(_ arguments: JSON, opensItem: Bool) async throws -> ToolResult {
		let op = opensItem ? "open" : "launch"
		var selector: (path: String?, bundleID: String?) = (nil, nil)
		var itemPath: String?
		var itemURL: String?
		if opensItem {
			guard let item = arguments["item"], let keys = item.keys, keys.count == 1 else {
				throw invalid("Open accepts exactly one item path or url and an optional application.")
			}
			if keys[0] == "path" {
				guard let path = item["path"]?.string, path.utf16.count <= 4096, path.hasPrefix("/"), !path.contains("\0") else {
					throw invalid("Use an existing absolute item path.")
				}
				itemPath = path
			} else {
				guard keys[0] == "url", let url = item["url"]?.string, url.utf16.count <= 4096,
				      url.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
				      !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
				else { throw invalid("Use a complete absolute URL with an explicit scheme and no control characters.") }
				itemURL = url
			}
			if let value = arguments["application"] { selector = try application(value) }
			var request: [(String, JSON)] = [("op", "open"), ("item", arguments["item"]!)]
			if let value = arguments["application"] { request.append(("application", value)) }
			guard JSON.object(request).text.utf8.count <= 16_384 else { throw invalid("The open request exceeds 16 KiB.") }
		} else {
			selector = try application(arguments["application"])
		}

		var outcome = "refused"
		var native: JSON?
		var launched: Mac.Launched?
		var fresh = false
		var created: JSON?
		var message: String?
		var error: JSON?
		let uncertain = opensItem ? openUncertain : launchUncertain
		var invoked = false
		do {
			// The native client's own checks, which also prove the application and item exist.
			if let path = selector.path {
				var directory: ObjCBool = false
				guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
				      Bundle(url: URL(fileURLWithPath: path))?.executableURL != nil
				else { throw ToolError("Use an existing absolute .app path for launch.") }
			}
			var urls: [URL] = []
			if let itemPath {
				guard FileManager.default.fileExists(atPath: itemPath) else { throw ToolError("Use an existing absolute item path.") }
				urls = [URL(fileURLWithPath: itemPath)]
			} else if let itemURL {
				guard let url = URL(string: itemURL, encodingInvalidCharacters: false), let scheme = url.scheme,
				      scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil, url.absoluteString == itemURL
				else { throw ToolError("Use a correctly encoded absolute URL with an explicit scheme and no control characters.") }
				// LaunchServices hands file URLs to apps as documents, so a query or fragment would be dropped silently.
				guard !url.isFileURL || (url.query == nil && url.fragment == nil) else {
					throw ToolError("A file URL's query or fragment is dropped when the file is opened as a document. Serve the file over http to keep it, or open the file without one.")
				}
				urls = [url]
			}
			if Mac.sessionLocked { throw ManageFailure.lockedOpening }
			let before = Mac.windowNumbers()
			invoked = true
			let result = try await Mac.launch(path: selector.path, bundleID: selector.bundleID, urls: urls)
			launched = result
			native = result.outcome
			let state = result.outcome["state"]?.string
			fresh = result.outcome["dispatch_state"]?.string == "dispatched"
			if opensItem {
				guard state == "dispatched_unverified", result.outcome["evidence"]?.string == "delivery_accepted" else {
					throw ToolError("The native runtime did not distinguish accepted item delivery from its effect. Inspect the receiving app before acting again.")
				}
				outcome = "completed"
				message = "macOS accepted the item opening request. Its effect is unverified; inspect the receiving app before any further action."
			} else {
				outcome = switch state {
				case "confirmed_change", "confirmed_no_change": "completed"
				case "refused": "refused"
				default: "unknown"
				}
			}
			if fresh { created = await createdWindows(pid: result.pid, generation: result.generation, before: before, seconds: 2) }
		} catch let failure as ManageFailure {
			outcome = failure.dispatched ? "unknown" : "refused"
			native = failure.outcome
			fresh = failure.dispatched
			error = .object(["code": "DESKTOP_ACTION_FAILED", "message": JSON(failure.message), "hint": (failure.dispatched ? uncertain : failure.hint).map(JSON.string)])
		} catch let thrown {
			outcome = invoked ? "unknown" : "refused"
			fresh = invoked
			error = .object([
				"code": "DESKTOP_ACTION_FAILED", "message": JSON((thrown as? ToolError)?.message ?? String(describing: thrown)),
				"hint": invoked ? Optional(JSON(uncertain)) : nil,
			])
		}
		let target = launched.map { JSON.object([("pid", JSON($0.pid)), ("process_start_identity_decimal", JSON(String($0.generation)))]) }
		let data = JSON.object([
			"action": JSON(op), "outcome": JSON(outcome), "native_outcome": native,
			"application": launched.map { app in
				JSON.object(["name": JSON(app.name), "bundle_id": app.bundleID.map(JSON.string), "path": app.path.map(JSON.string), "target": target])
			},
			"requires_fresh_observation": JSON(fresh), "created_windows": created, "message": message.map(JSON.string), "error": error,
			"target_receipt": target,
		])
		if outcome != "completed" { return actionResult(data, outcome) }
		return await observeManagement(op, action: data, target: target ?? .null, window: nil)
	}
}
