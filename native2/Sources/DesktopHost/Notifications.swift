import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_notifications and desktop_notification_action, ported from src/notifications.ts: Notification Center's
// windows read through the same apps, windows and inspect reads an agent makes, and acted on through a click or
// one of its listed custom actions.

/// Notification Center's process; its banners, alerts and open panel are windows of it.
private let notificationCenter = "com.apple.notificationcenterui"
/// Hosts of system alerts such as permission prompts, which desktop_dialog reads and answers.
private let alertHosts = ["com.apple.UserNotificationCenter", "com.apple.SecurityAgent"]
private let maxWindows = 8
private let maxEntries = 40
private let maxTexts = 8
private let maxEntryText = 1000
private let maxActionName = 64
/// The native client's error codes that mean the notification's element went away.
private let goneCodes: Set = ["SNAPSHOT_NOT_FOUND", "SNAPSHOT_STALE", "ELEMENT_NOT_FOUND", "STALE_ELEMENT", "WINDOW_NOT_FOUND"]

/// The entries of the latest read by ID, so an action can tell whether its notification went away.
private actor LastRead {
	static let shared = LastRead()
	private var entries: [String: JSON] = [:]
	func replace(_ list: [JSON]) {
		entries = [:]
		for entry in list { if let id = entry["id"]?.string { entries[id] = entry } }
	}
	func get(_ id: String) -> JSON? { entries[id] }
}

/// JavaScript's `text.slice(0, n)`, counted in UTF-16 code units.
private func jsPrefix(_ text: String, _ count: Int) -> String {
	guard text.utf16.count > count else { return text }
	return String(text.utf16.prefix(count)) ?? String(text.utf16.prefix(count - 1)) ?? ""
}

private func clip(_ text: JSON?) -> String? {
	guard let text = text?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
	return jsPrefix(text, maxEntryText)
}

private func axRole(_ element: JSON) -> String {
	element["attributes"]?["role"]?.string ?? element["role"]?.string ?? ""
}

/// Banners, alerts and their stacks: Notification Center elements that list custom actions or its subroles.
private func isEntry(_ element: JSON) -> Bool {
	element["attributes"]?["customActions"]?.string != nil
		|| element["attributes"]?["subrole"]?.string?.hasPrefix("AXNotificationCenter") == true
}

private func depth(_ element: JSON) -> Double {
	element["attributes"]?["depth"]?.string.flatMap(Double.init) ?? 0
}

/// The end of an element's descendants in the preorder list, from its depth attribute.
private func subtreeEnd(_ elements: [JSON], _ index: Int) -> Int {
	let level = depth(elements[index])
	var end = index + 1
	while end < elements.count, depth(elements[end]) > level { end += 1 }
	return end
}

/// Reads fields by text identifier where the system provides one, otherwise by position.
private func fields(_ texts: [(text: String, identifier: String)], description: String?) -> [(String, JSON)] {
	func named(_ pattern: String) -> String? {
		texts.first { $0.identifier.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.text
	}
	// In the macOS 11–15 structure a notification's description starts with the posting app's name.
	let first = description.map { String($0.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
	let app = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
	let value = { (text: String?) in JSON(text) }
	if texts.contains(where: { !$0.identifier.isEmpty }) {
		return [
			("app", value(named("app") ?? app)),
			("title", value(named("^title$") ?? named("title"))),
			("subtitle", value(named("subtitle"))),
			("body", value(named("body|message"))),
			("time", value(named("date|time"))),
			("fields_from", "identifiers"),
		]
	}
	// In the macOS 11–15 structure a banner's texts are its title, an optional subtitle and its body.
	let values = texts.map(\.text)
	return [
		("app", value(app)),
		("title", value(values.first)),
		("subtitle", value(values.count > 2 ? values[1] : nil)),
		("body", value(values.count > 1 ? values.last : nil)),
		("time", .null),
		("fields_from", "order"),
	]
}

/// The notification entries of one Notification Center window inspection.
private func entries(_ inspection: JSON, pid: Int, window: Int) -> [JSON] {
	let elements = inspection["ui_elements"]?.array ?? []
	let snapshot = inspection["snapshot_id"]?.string ?? ""
	var found: [JSON] = []
	var index = 0
	while index < elements.count, found.count < maxEntries {
		defer { index += 1 }
		let element = elements[index]
		guard isEntry(element) else { continue }
		let end = subtreeEnd(elements, index)
		var texts: [(text: String, identifier: String)] = []
		var stack = false
		var inner = index + 1
		while inner < end {
			defer { inner += 1 }
			let child = elements[inner]
			if isEntry(child) {
				// A nested entry's texts belong to that entry.
				stack = true
				inner = subtreeEnd(elements, inner) - 1
				continue
			}
			guard axRole(child) == "AXStaticText", texts.count < maxTexts else { continue }
			if let text = clip(child["value"]) ?? clip(child["label"]) {
				texts.append((text, child["attributes"]?["identifier"]?.string ?? ""))
			}
		}
		let attributes = element["attributes"]
		let description = clip(element["label"])
		let custom = attributes?["customActions"]?.string?.split(separator: "\n").map(String.init) ?? []
		let id = element["id"].map { $0.string ?? $0.text } ?? "undefined"
		found.append(.object([
			("id", JSON("\(snapshot)/\(id)")),
			("pid", JSON(pid)),
			("window_id", JSON(window)),
			("kind", JSON(attributes?["subrole"]?.string ?? axRole(element))),
		] + fields(texts, description: description) + [
			("description", JSON(description)),
			("texts", .array(texts.map { JSON($0.text) })),
			("stack", JSON(stack)),
			("actions", .array((["open"] + custom.filter { $0 != "open" }).map(JSON.string))),
		]))
	}
	return found
}

/// What one read Node's notifications make through its own tools returns: parsed text, or the error it throws.
private func observe(_ tool: String, _ arguments: JSON) async throws -> (data: JSON, isError: Bool) {
	let result = await Tools.whole(tool, arguments: arguments)
	guard let data = try? JSON(parsing: result.text), case .object = data else { throw ToolError(result.text) }
	if result.isError, tool != "desktop_inspect" { throw ToolError(result.text) }
	return (data, result.isError)
}

/// The running apps with exactly this bundle ID; a query keeps a long inventory from cutting them off.
private func running(_ bundle: String) async throws -> (rows: [JSON], data: JSON) {
	let data = try await observe("desktop_apps", .object([("query", JSON(bundle))])).data
	return ((data["apps"]?.array ?? []).filter { $0["bundle_id"]?.string == bundle }, data)
}

/// Shown windows of the apps with this bundle ID.
private func shownWindows(_ bundle: String) async throws -> [(pid: Int, row: JSON)] {
	var shown: [(pid: Int, row: JSON)] = []
	for app in try await running(bundle).rows {
		guard let pid = app["pid"]?.int else { continue }
		let data = try await observe("desktop_windows", .object([("pid", JSON(pid))])).data
		for row in data["windows"]?.array ?? [] where row["is_on_screen"]?.bool == true { shown.append((pid, row)) }
	}
	return shown
}

private func message(_ error: Error) -> String {
	jsPrefix((error as? ToolError)?.message ?? String(describing: error), 2000)
}

extension Tools {
	static func notifications(_: JSON) async throws -> ToolResult {
		ToolResult(text: try bounded(try await readNotifications(), field: "notifications"))
	}

	/// Current banners and alerts, and the entries of an open Notification Center, each with an action ID.
	static func readNotifications() async throws -> JSON {
		let (rows, appsData) = try await running(notificationCenter)
		var alerts: [JSON] = []
		for host in alertHosts {
			do {
				for (pid, row) in try await shownWindows(host) {
					alerts.append(.object([
						("host", JSON(host)), ("pid", JSON(pid)), ("window_id", row["window_id"] ?? .null),
						("title", row["window_title"]?.string.flatMap { $0.isEmpty ? nil : JSON($0) } ?? .null),
						("target", row["target"] ?? .null),
					]))
				}
			} catch {
				alerts.append(.object([("host", JSON(host)), ("error", JSON(message(error)))]))
			}
		}
		guard let center = rows.first, let pid = center["pid"]?.int else {
			return .object([
				"notifications": .array([]),
				"notification_center_running": false,
				"inventory_completeness": appsData["inventory_completeness"],
				"system_alerts": .array(alerts),
			])
		}
		let shown = try await shownWindows(notificationCenter)
		var notifications: [JSON] = []
		var errors: [JSON] = []
		for (_, row) in shown.prefix(maxWindows) {
			guard let window = row["window_id"]?.int else { continue }
			do {
				let (data, failed) = try await observe("desktop_inspect", .object([("pid", JSON(pid)), ("window", JSON(window))]))
				if failed {
					errors.append(.object([("window_id", JSON(window)), ("error", data["inspection_error"] ?? data)]))
					continue
				}
				notifications += entries(data, pid: pid, window: window)
				if data["truncated"]?.bool == true {
					errors.append(.object([("window_id", JSON(window)), ("error", "The window's elements were truncated.")]))
				}
			} catch {
				errors.append(.object([("window_id", JSON(window)), ("error", JSON(message(error)))]))
			}
		}
		let listed = Array(notifications.prefix(maxEntries))
		await LastRead.shared.replace(listed)
		var centerFields: [(String, JSON)] = [
			("pid", JSON(pid)),
			("shown_windows", .array(shown.map { _, row in
				.object([
					("window_id", row["window_id"] ?? .null),
					("title", row["window_title"]?.string.flatMap { $0.isEmpty ? nil : JSON($0) } ?? .null),
					("bounds", row["bounds"] ?? .null),
				])
			})),
		]
		if shown.count > maxWindows { centerFields.append(("windows_not_read", JSON(shown.count - maxWindows))) }
		return .object([
			"notifications": .array(listed),
			"notification_center": .object(centerFields),
			"errors": errors.isEmpty ? nil : .array(errors),
			"system_alerts": .array(alerts),
		])
	}

	/// Opens, closes or runs one listed action of one notification through Accessibility, then reads again: the
	/// result is completed only when the notification is gone, otherwise unknown.
	static func notificationAction(_ arguments: JSON) async -> ToolResult {
		func result(_ data: [(String, JSON)], _ outcome: String) -> ToolResult {
			ToolResult(text: JSON.object([("action", .object(data))]).text, outcome: outcome, isError: outcome != "completed")
		}
		let id: String, snapshot: String, element: String, action: String
		do {
			(id, snapshot, element, action) = try notificationArguments(arguments)
		} catch {
			return result([("outcome", "refused"), ("reason", JSON(message(error))), ("message", "No input was sent.")], "refused")
		}
		let before = await LastRead.shared.get(id)
		// "open" is the default click; every other action is a custom action the snapshot listed by name.
		let raw: ToolResult
		if action == "open" {
			raw = await act("click", snapshotID: snapshot, element: element, observe: false) { snapshot, target in
				let window = window(snapshot)
				try window.check()
				do { return try Mac.clickElement(target!.reference, window: window) } catch is Unsupported {
					return try Mac.clickPoint(CGPoint(x: target!.frame.midX, y: target!.frame.midY), window: window)
				}
			}
		} else {
			let name = action == "close" ? "Close" : action
			raw = await act("element-action", snapshotID: snapshot, element: element, observe: false, precheck: { _, observed in
				// Only Notification Center elements list custom actions, by their exact names.
				let listed = observed?.attributes["customActions"]?.split(separator: "\n").map(String.init) ?? []
				guard listed.contains(name) else {
					throw ToolError(listed.isEmpty
						? "The observed element lists no custom actions."
						: "The observed element does not list \(name). It lists \(listed.joined(separator: ", ")).")
				}
			}) { snapshot, target in
				var delivery = try Mac.performCustomAction(target!.reference, id: element, named: name, window: window(snapshot))
				delivery.fields.append(("element_action", JSON("AXCustomAction:\(name)")))
				return delivery
			}
		}
		guard var data = (try? JSON(parsing: raw.text))?["action"] else {
			return result([("outcome", "unknown"), ("reason", JSON(raw.text)), ("message", "The notification action may have run. Read notifications again before acting further.")], "unknown")
		}
		let native = data["outcome"]?.string
		if native == "refused" {
			let code = data["error"]?["code"]?.string ?? ""
			let text = data["error"]?["message"]?.string ?? ""
			if goneCodes.contains(code) || text.range(of: "no longer|not in this snapshot|stale", options: [.regularExpression, .caseInsensitive]) != nil {
				data.set("message", "Notification gone; read again with desktop_notifications.")
			}
			return result(data.pairs ?? [], "refused")
		}
		// Read again: the notification counts as acted on only once it is gone.
		do {
			let after = try await readNotifications()
			let remaining = after["notifications"]?.array ?? []
			let still = before.map { before in remaining.contains { sameEntry(before, $0) } } ?? true
			let outcome = !still && after["errors"] == nil && native == "completed" ? "completed" : "unknown"
			var fields: [(String, JSON)] = [
				("outcome", JSON(outcome)), ("action", JSON(action)), ("native_outcome", JSON(native)),
				("notification_gone", before == nil ? .null : JSON(!still)),
			]
			if outcome == "unknown" {
				fields.append(("message", before != nil && still
						? "The notification is still shown; the action may not have taken effect, or it changed the notification. Read again before acting further."
						: "The result could not be confirmed. Read notifications again before acting further."))
			}
			fields += [("native", data), ("notifications", .array(remaining))]
			return result(fields, outcome)
		} catch {
			return result([
				("outcome", "unknown"), ("action", JSON(action)), ("native_outcome", JSON(native)),
				("observation_error", JSON(message(error))),
				("message", "Read notifications again before acting further; do not repeat the action blindly."),
				("native", data),
			], "unknown")
		}
	}

	/// Node's validateNotificationAction: an id from desktop_notifications and one action name.
	private static func notificationArguments(_ arguments: JSON) throws -> (String, String, String, String) {
		guard let id = arguments["id"]?.string, id.utf16.count <= 600 else {
			throw ToolError("Pass a notification id from desktop_notifications.")
		}
		let split = id.lastIndex(of: "/")
		let snapshot = split.map { String(id[..<$0]) } ?? ""
		let element = split.map { String(id[id.index(after: $0)...]) } ?? ""
		guard let split, split != id.startIndex, !element.isEmpty, snapshot.utf16.count <= 256, element.utf16.count <= 256 else {
			throw ToolError("Pass a notification id from desktop_notifications.")
		}
		guard let action = arguments["action"]?.string, !action.isEmpty, action.unicodeScalars.count <= maxActionName,
		      !action.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
		else { throw ToolError("Choose open, close, or one of the notification's listed actions.") }
		return (id, snapshot, element, action)
	}

	/// Whether a later read still shows the entry: same window, kind and texts.
	private static func sameEntry(_ entry: JSON, _ other: JSON) -> Bool {
		entry["window_id"] == other["window_id"] && entry["kind"] == other["kind"]
			&& entry["texts"] == other["texts"] && entry["description"] == other["description"]
	}
}
