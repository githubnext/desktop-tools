import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

private let menuWarnings: [JSON] = [
	"Native menu reads may reuse a cached structure; its observation time is unavailable. The cache expires 2 seconds after the original traversal finishes.",
	"Native completeness is unknown: lazy submenus, unavailable AX attributes and traversal limits may omit items. An empty subtree does not establish that no commands exist.",
	"Paths are literal title arrays for discovery, not input authority. Enabled and checked states are omitted because unavailable native attributes receive default values.",
]

/// An application target as Node's validateAppTarget checks it: a pid and a canonical process generation.
func appTargetArgument(_ target: JSON?, only: Bool = true) throws -> (pid: pid_t, generation: UInt64) {
	guard let target, target.pairs != nil, let pid = target["pid"]?.int, (1...2_147_483_647).contains(pid),
	      let identity = target["process_start_identity_decimal"]?.string, identity.count <= 20,
	      identity.first.map({ ("1"..."9").contains($0) }) == true, identity.allSatisfy({ ("0"..."9").contains($0) }),
	      let generation = UInt64(identity)
	else { throw ToolError("Pass the application's target object from fresh desktop inventory unchanged.") }
	if only, target.keys!.contains(where: { $0 != "pid" && $0 != "process_start_identity_decimal" }) {
		throw ToolError("Pass only the application's target object from desktop_apps.")
	}
	return (pid_t(pid), generation)
}

/// The application target as the native client echoes it.
func appTargetJSON(_ pid: pid_t, _ generation: UInt64) -> JSON {
	.object([("pid", JSON(pid)), ("process_start_identity_decimal", JSON(String(generation)))])
}

private func menuPath(_ value: JSON?) throws -> [String] {
	guard let list = value?.array, (1...8).contains(list.count),
	      let titles = Optional(list.compactMap(\.string)), titles.count == list.count,
	      titles.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 512 })
	else { throw ToolError("Menu path requires 1 to 8 nonblank literal titles of at most 512 UTF-16 code units each.") }
	return titles
}

extension Tools {
	static func menus(_ arguments: JSON) async throws -> ToolResult {
		let (pid, generation) = try appTargetArgument(arguments["target"])
		let path = try arguments["path"].map { try menuPath($0) }
		var request: [(String, JSON)] = [("op", "menus"), ("target", arguments["target"]!)]
		if let path { request.append(("path", .array(path.map(JSON.string)))) }
		guard JSON.object(request).text.utf8.count <= 4096 else { throw ToolError("Menu request exceeds the 4096-byte limit.") }
		let unverified = ToolError("DESKTOP_ERROR: The observed application generation could not be verified. Refresh desktop_apps before reading its menus..")
		guard Mac.isRunning(pid, generation: generation) else { throw unverified }
		let structure = try await run { try Mac.menus(pid: pid) }
		guard Mac.isRunning(pid, generation: generation) else { throw unverified }
		var rows = structure.rows
		let total = rows.count
		var filter: JSON?
		if let path {
			for count in 1...path.count {
				let prefix = Array(path.prefix(count))
				let matches = rows.filter { $0.path == prefix }.count
				guard matches == 1 else {
					throw ToolError(matches == 0
						? "DESKTOP_ERROR: The requested menu path was not found in the returned native inventory; lazy menus or native limits may omit it.."
						: "DESKTOP_ERROR: The requested menu path is ambiguous in the returned native inventory..")
				}
			}
			rows = rows.filter { $0.path.starts(with: path) }
			filter = .object([
				("path", .array(path.map(JSON.string))), ("scope", "returned_native_inventory"), ("total", JSON(total)), ("matched", JSON(rows.count)),
			])
		}
		let data: JSON = .object([
			"target": appTargetJSON(pid, generation),
			"application_name": JSON(structure.applicationName),
			"bundle_id": structure.bundleID.map(JSON.string),
			"menus": .array(rows.map { row in
				.object(["path": .array(row.path.map(JSON.string)), "kind": JSON(row.kind), "shortcut": row.shortcut.map(JSON.string)])
			}),
			"native_row_count": JSON(total),
			"filter": filter,
			"native_completeness": "unknown",
			"cache_may_be_used": true,
			"cache_ttl_ms": 2000,
			"warnings": .array(menuWarnings),
		])
		return ToolResult(text: try bounded(data, field: "menus"))
	}

	static func menu(_ arguments: JSON) async throws -> ToolResult {
		let (pid, generation) = try appTargetArgument(arguments["target"])
		let path = try menuPath(arguments["path"])
		let request: JSON = .object([("op", "menu"), ("target", arguments["target"]!), ("path", .array(path.map(JSON.string)))])
		guard request.text.utf8.count <= 4096 else { throw ToolError("Menu request exceeds the 4096-byte limit.") }

		var action: [(String, JSON)] = [("outcome", "refused"), ("action", "menu")]
		func result(_ outcome: String, receipt: Bool) -> ToolResult {
			action[0] = ("outcome", JSON(outcome))
			if receipt { action.append(("target_receipt", appTargetJSON(pid, generation))) }
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: outcome, isError: outcome != "completed")
		}
		func refused(_ refusal: Refusal, receipt: Bool) -> ToolResult {
			action += [
				("native_outcome", refusal.outcome),
				("requires_fresh_observation", JSON(!["operation_unsupported", "invalid_request"].contains(refusal.reason))),
				("error", errorJSON(refusal.code, refusal.message, hint: refusal.hint)),
			]
			return result("refused", receipt: receipt)
		}
		if Mac.sessionLocked {
			return refused(Refusal("DESKTOP_ACTION_FAILED", "The macOS GUI session is locked. No menu command was dispatched.",
			                       hint: "Unlock the active user session and refresh the application and its menus."), receipt: false)
		}
		guard Mac.isRunning(pid, generation: generation) else {
			action += [("requires_fresh_observation", false),
			           ("error", errorJSON("DESKTOP_ACTION_FAILED", "The observed application generation could not be attested before the menu command."))]
			return result("refused", receipt: false)
		}
		let before = Mac.windowIDs()
		do {
			let delivery = try await run { try Mac.menuCommand(pid: pid, generation: generation, path: path) }
			action += [("native_outcome", delivery.json), ("requires_fresh_observation", true)]
			if let created = await createdWindows(pid: pid, generation: generation, before: before) { action.append(("created_windows", created)) }
			return result("completed", receipt: true)
		} catch let refusal as Refusal {
			return refused(refusal, receipt: true)
		} catch {
			action += [
				("native_outcome", Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: 1).json),
				("requires_fresh_observation", true),
				("error", errorJSON("DESKTOP_ACTION_FAILED", "The menu command may have been delivered; native completion is unknown.",
				                    hint: "A modal command may still be running. Observe the application before deciding what to do; do not blindly repeat it.")),
			]
			return result("unknown", receipt: true)
		}
	}

	/// The app's windows that appeared after an action, waiting up to `seconds` for one; nil when they can't be listed.
	static func createdWindows(pid: pid_t, generation: UInt64, before: Set<Int>, seconds: Int = 1) async -> JSON? {
		await Mac.awaitNewWindow(pid: pid, before: before, seconds: Double(seconds))
		guard let listing = try? await Mac.windows(pid: pid) else { return nil }
		let windows = (listing["windows"]?.array ?? []).filter { row in
			row["window_id"]?.int.map { !before.contains($0) } == true && row["process_start_identity_decimal"]?.string == String(generation)
		}
		let (attribution, note): (String, String) = switch windows.count {
		case 0: ("none", "No new window of the app appeared within about \(seconds == 1 ? "1 second" : "\(seconds) seconds"). One may still open later, or the action may reuse an existing window; list desktop_windows before acting.")
		case 1: ("exclusive", "This is the only window of the app that appeared after the action was sent, so it is very likely the one the action opened. Another agent acting on the same app at the same moment can still open a window in this interval; if that matters, confirm its contents with desktop_inspect.")
		default: ("ambiguous", "Several windows of the app appeared after the action was sent. The action may have opened more than one, or something else opened the others at the same time; nothing here says which came from this action. Inspect them, or ask the user, before choosing one.")
		}
		return .object([("windows", .array(windows)), ("attribution", JSON(attribution)), ("note", JSON(note))])
	}
}

/// An action's error object, without the fields it lacks.
func errorJSON(_ code: String, _ message: String, hint: String? = nil, cause: String? = nil) -> JSON {
	.object(["code": JSON(code), "message": JSON(message), "hint": hint.map(JSON.string), "cause": cause.map(JSON.string)])
}
