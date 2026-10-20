import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_wait and an action's expect, ported from src/wait.ts. Each poll reads in this process, so a wait
// costs no extra round trips; it still holds nothing between polls.

private let waitDefault = 10_000
private let waitMax = 45_000
let expectDefault = 3_000
let expectMax = 10_000
private let firstDelay = 200
private let maxDelay = 2_000
private let maxRows = 10
private let maxWaitText = 8192
private let matchLimit = 20

private let appConditions = ["app_running", "app_frontmost", "app_quit"]
private let elementConditions = ["element_appears", "element_gone"]
private let textConditions = ["text_changes", "text_equals", "text_contains"]
private let conditions = ["window_appears", "window_gone", "dialog_appears", "dialog_gone"] + elementConditions + textConditions + appConditions

/// One poll's verdict and what it saw, in the read tools' shapes.
struct Check: Sendable {
	var holds: Bool
	var observation: JSON
}

/// A validated wait condition.
struct WaitCondition: Sendable {
	let until: String
	let request: JSON
	let timeout: Int

	var pid: pid_t? { request["pid"]?.int.flatMap(Int32.init(exactly:)) }
	var bundleID: String? { request["bundle_id"]?.string }
	var window: Int? { request["window"]?.int }
	var element: JSON? { request["element"] }

	/// Refuses argument combinations a condition doesn't use, so a misplaced filter is never silently ignored.
	init(_ request: JSON, maxTimeout: Int = waitMax, defaultTimeout: Int = waitDefault) throws {
		guard let until = request["until"]?.string, conditions.contains(until) else {
			throw ToolError("Choose until from \(conditions.joined(separator: ", ")).")
		}
		func positive(_ key: String) throws {
			guard let value = request[key]?.int, value >= 1 else { throw ToolError("\(key) must be a positive integer.") }
		}
		func exact(_ key: String, _ value: JSON?, limit: Int = 512) throws {
			guard let text = value?.string, !text.isEmpty, text.count <= limit else {
				throw ToolError("\(key) must be a non-empty string of at most \(limit) characters.")
			}
		}
		var allowed: Set<String> = ["op", "until", "timeout_ms"]
		if until == "window_appears" || appConditions.contains(until) {
			guard (request["bundle_id"] == nil) != (request["pid"] == nil) else {
				throw ToolError("\(until) takes exactly one of bundle_id or pid.")
			}
			allowed.formUnion(["bundle_id", "pid"])
			if let id = request["bundle_id"] {
				try exact("bundle_id", id, limit: 256)
				guard id.string!.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
					throw ToolError("bundle_id must be an exact bundle ID.")
				}
			}
		} else {
			try positive("pid")
			allowed.insert("pid")
		}
		if request["pid"] != nil { try positive("pid") }
		if until == "window_appears" {
			if request["title"] != nil, request["title_contains"] != nil { throw ToolError("Supply title or title_contains, not both.") }
			if let title = request["title"], title.string == nil { throw ToolError("title must be a string.") }
			if let contains = request["title_contains"] { try exact("title_contains", contains) }
			allowed.formUnion(["title", "title_contains"])
		}
		if until == "window_gone" || until.hasPrefix("dialog_") || elementConditions.contains(until) || textConditions.contains(until) {
			allowed.insert("window")
			if request["window"] != nil || !until.hasPrefix("dialog_") { try positive("window") }
		}
		if elementConditions.contains(until) || textConditions.contains(until) {
			allowed.formUnion(["scope", "element", "web_accessibility"])
			if elementConditions.contains(until), request["element"] == nil { throw ToolError("\(until) needs element.") }
			if let match = request["element"] { try Self.validateMatch(match, forText: textConditions.contains(until)) }
			if let web = request["web_accessibility"], web.bool == nil { throw ToolError("Choose web_accessibility true or false.") }
		}
		if until == "text_equals" || until == "text_contains" {
			allowed.insert("text")
			guard let text = request["text"]?.string, text.utf16.count <= maxWaitText, until == "text_equals" || !text.isEmpty else {
				throw ToolError("\(until) needs text of at most \(maxWaitText) characters\(until == "text_contains" ? ", not empty" : "").")
			}
		}
		if let timeout = request["timeout_ms"] {
			guard let value = timeout.int, (100...maxTimeout).contains(value) else {
				throw ToolError("timeout_ms must be an integer from 100 to \(maxTimeout).")
			}
		}
		let extra = (request.keys ?? []).filter { !allowed.contains($0) && request[$0] != nil }
		if !extra.isEmpty { throw ToolError("\(until) doesn't use \(extra.joined(separator: ", ")).") }
		for unported in ["scope", "web_accessibility"] where request[unported] != nil {
			throw ToolError("desktop_wait's \(unported) isn't in the Swift spike yet.")
		}
		if until.hasPrefix("dialog_") || textConditions.contains(until) {
			throw ToolError("desktop_wait's \(until) isn't in the Swift spike yet.")
		}
		self.until = until
		self.request = request
		timeout = request["timeout_ms"]?.int ?? defaultTimeout
	}

	private static func validateMatch(_ match: JSON, forText: Bool) throws {
		guard case .object = match else { throw ToolError("element must be an object.") }
		let keys = forText ? ["role", "title", "identifier"] : ["role", "title", "value", "identifier"]
		if (match.keys ?? []).contains(where: { !keys.contains($0) }) {
			throw ToolError("element takes \(keys.joined(separator: ", "))\(forText ? "; the text it waits on is the element's value" : "").")
		}
		guard let role = match["role"]?.string, !role.isEmpty, role.count <= 128 else {
			throw ToolError("element.role must be a non-empty string of at most 128 characters.")
		}
		for key in keys.dropFirst() {
			if let value = match[key], value.string == nil || value.string!.count > maxWaitText {
				throw ToolError("element.\(key) must be a string of at most \(maxWaitText) characters.")
			}
		}
		if keys.dropFirst().allSatisfy({ match[$0] == nil }) {
			throw ToolError("element needs role and at least one of \(keys.dropFirst().joined(separator: ", ")).")
		}
	}

	// MARK: Reads

	/// Apps with the bundle ID or PID; a partial inventory never proves an app is gone.
	func findApps() async throws -> (rows: [JSON], complete: Bool) {
		let data = try await Mac.apps()
		let rows = (data["apps"]?.array ?? []).filter { app in
			if let pid { return app["pid"]?.int == Int(pid) }
			return app["bundle_id"]?.string == bundleID
		}
		return (rows, data["inventory_completeness"]?.string == "complete")
	}

	static func listWindows(_ pid: pid_t) async throws -> (rows: [JSON], complete: Bool, hidden: Bool) {
		let data = try await Mac.windows(pid: pid)
		return (data["windows"]?.array ?? [], data["inventory_completeness"]?.string == "complete", data["app_hidden"]?.bool == true)
	}

	/// Whether a window counts as open; see windowShown in src/wait.ts.
	static func shown(_ row: JSON, appHidden: Bool) -> Bool {
		if row["is_on_screen"]?.bool == true || row["is_minimized"]?.bool == true { return true }
		let spaces = row["space_ids"]?.array?.compactMap(\.int) ?? []
		if spaces.isEmpty { return false }
		guard let current = row["display_current_space_id"]?.int, !appHidden, row["display_asleep"]?.bool != true else { return true }
		return !spaces.contains(current)
	}

	/// The window's row, or why it is certainly gone.
	func findWindow(_ pid: pid_t, _ window: Int) async throws -> (row: JSON?, gone: String?) {
		let listed: (rows: [JSON], complete: Bool, hidden: Bool)
		do { listed = try await Self.listWindows(pid) } catch {
			try Task.checkCancellation()
			if Mac.generation(pid) == nil { return (nil, "app_not_running") }
			throw error
		}
		if let row = listed.rows.first(where: { $0["window_id"]?.int == window }) { return (row, nil) }
		return (nil, listed.complete ? "window_closed" : nil)
	}

	/// Matching elements of one window, read through Accessibility alone with the wide budget.
	func findElements() async throws -> JSON {
		guard let pid, let window, let match = element else { throw ToolError("Read matching elements of one window.") }
		var budget = ElementBudget()
		budget.maxDepth = 64
		budget.maxElements = 4000
		budget.maxChildren = 1000
		let wide = budget
		let generation = Mac.generation(pid)
		let tree = try await run { try Mac.elements(pid: pid, windowID: window, budget: wide) }
		let found = tree.elements.filter { element in
			let attributes = element.attributes
			guard attributes["role"] == match["role"]?.string || element.type == match["role"]?.string else { return false }
			if let title = match["title"]?.string, element.label != title, attributes["title"] != title { return false }
			if let value = match["value"]?.string, Self.readable(element) != value { return false }
			if let identifier = match["identifier"]?.string, attributes["identifier"] != identifier { return false }
			return true
		}
		let truncation = tree.warnings.map { $0 == "ax_truncated_incomplete" ? "ax_incomplete_read" : $0 }
		return .object([
			"application_name": Mac.appName(pid).map(JSON.string),
			"window_title": tree.windowTitle.map(JSON.string),
			"matches": .array(found.prefix(matchLimit).map { element in
				.object([
					"role": JSON(element.attributes["role"] ?? element.type),
					"label": element.label.map(JSON.string),
					"value": Self.readable(element).map(JSON.string),
					"title": element.attributes["title"].map(JSON.string),
					"identifier": element.attributes["identifier"].map(JSON.string),
					"depth": JSON(Int(element.attributes["depth"] ?? "0") ?? 0),
					"bounds": .object([("x", JSON(Double(element.frame.minX))), ("y", JSON(Double(element.frame.minY))), ("width", JSON(Double(element.frame.width))), ("height", JSON(Double(element.frame.height)))]),
					"is_enabled": JSON(element.isEnabled),
				])
			}),
			"match_count": JSON(found.count),
			"element_count": JSON(tree.elements.count),
			"traversed_element_count": JSON(tree.elements.count),
			"truncated": JSON(!truncation.isEmpty),
			"truncation": .array(truncation.map(JSON.string)),
			"target_receipt": generation.map { .object([
				("pid", JSON(pid)), ("process_start_identity_decimal", JSON(String($0))), ("window_id", JSON(window)),
			]) },
		])
	}

	/// Secure text field values are never read.
	private static func readable(_ element: Element) -> String? {
		element.attributes["role"] == "AXSecureTextField" || element.attributes["subrole"] == "AXSecureTextField" ? nil : element.value
	}

	// MARK: Conditions

	func check() async throws -> Check {
		if appConditions.contains(until) {
			let (rows, complete) = try await findApps()
			let observation: JSON = .object([("apps", .array(Array(rows.prefix(maxRows)))), ("inventory_completeness", JSON(complete ? "complete" : "partial"))])
			switch until {
			case "app_running": return Check(holds: !rows.isEmpty, observation: observation)
			case "app_frontmost": return Check(holds: rows.contains { $0["is_active_known"]?.bool == true && $0["is_active"]?.bool == true }, observation: observation)
			default: return Check(holds: complete && rows.isEmpty, observation: observation)
			}
		}
		if until == "window_appears" {
			let pids = if let pid { [pid] } else { try await findApps().rows.compactMap { $0["pid"]?.int.flatMap(Int32.init(exactly:)) } }
			var seen: [JSON] = [], matched: [JSON] = [], errors: [String] = []
			for pid in pids {
				do {
					let (rows, _, hidden) = try await Self.listWindows(pid)
					for row in rows where Self.shown(row, appHidden: hidden) {
						let title = row["window_title"]?.string ?? ""
						let fits = if let exact = request["title"]?.string { title == exact } else { request["title_contains"]?.string.map(title.contains) ?? true }
						var entry: JSON = .object([("pid", JSON(pid))])
						for (key, value) in row.pairs ?? [] { entry.set(key, value) }
						if fits { matched.append(entry) } else { seen.append(entry) }
					}
				} catch {
					try Task.checkCancellation()
					errors.append((error as? ToolError)?.message ?? String(describing: error))
				}
			}
			if !matched.isEmpty { return Check(holds: true, observation: .object([("windows", .array(Array(matched.prefix(maxRows))))])) }
			return Check(holds: false, observation: .object([
				"running_pids": .array(pids.map { JSON($0) }),
				"windows": .array(Array(seen.prefix(maxRows))),
				"errors": errors.isEmpty ? nil : .array(errors.map(JSON.string)),
			]))
		}
		if until == "window_gone" {
			let (row, gone) = try await findWindow(pid!, window!)
			if let gone { return Check(holds: true, observation: .object([("pid", JSON(pid!)), ("window_id", JSON(window!)), ("reason", JSON(gone))])) }
			if let row {
				var entry: JSON = .object([("pid", JSON(pid!))])
				for (key, value) in row.pairs ?? [] { entry.set(key, value) }
				return Check(holds: false, observation: entry)
			}
			return Check(holds: false, observation: .object([("pid", JSON(pid!)), ("window_id", JSON(window!)), ("inventory_completeness", "partial")]))
		}
		// element_appears or element_gone
		let appears = until == "element_appears"
		let found: JSON
		do { found = try await findElements() } catch {
			try Task.checkCancellation()
			if !appears, let gone = try await findWindow(pid!, window!).gone {
				return Check(holds: true, observation: .object([("pid", JSON(pid!)), ("window_id", JSON(window!)), ("reason", JSON(gone))]))
			}
			return Check(holds: false, observation: .object([("error", JSON((error as? ToolError)?.message ?? String(describing: error)))]))
		}
		let count = found["match_count"]?.int ?? 0
		// A cut-short traversal may have missed the element, so it never proves absence.
		return Check(holds: appears ? count > 0 : count == 0 && found["truncated"]?.bool == false, observation: found)
	}

	/// Polls with backoff until the condition holds or the timeout passes. Sends no input.
	func poll() async throws -> (last: Check?, lastError: String?, polls: Int, elapsed: Int) {
		let started = ContinuousClock.now
		let deadline = started + .milliseconds(timeout)
		var last: Check?, lastError: String?, polls = 0
		var delay = firstDelay
		while true {
			do {
				last = try await withDeadline(deadline) { try await self.check() }
				lastError = nil
				polls += 1
			} catch is DeadlinePassed {
				break
			} catch {
				try Task.checkCancellation()
				polls += 1
				lastError = (error as? ToolError)?.message ?? String(describing: error)
			}
			if last?.holds == true { break }
			// Like Node, the last sleep runs to the deadline, which ends the wait without another read.
			let remaining = ContinuousClock.now.duration(to: deadline)
			if remaining <= .milliseconds(delay) {
				if remaining > .zero { try await Task.sleep(for: remaining) }
				break
			}
			try await Task.sleep(for: .milliseconds(delay))
			delay = min(Int((Double(delay) * 1.5).rounded()), maxDelay)
		}
		let elapsed = started.duration(to: .now)
		return (last, lastError, polls, Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
	}

	/// What a poll ended with, in desktop_wait's result shape; an appeared element also gets a snapshot.
	func report(_ polled: (last: Check?, lastError: String?, polls: Int, elapsed: Int)) async -> (matched: Bool, result: JSON, image: (data: String, mimeType: String)?) {
		let matched = polled.last?.holds == true
		var result: JSON = .object([("until", JSON(until)), ("status", JSON(matched ? "matched" : "timed_out")), ("elapsed_ms", JSON(polled.elapsed)), ("polls", JSON(polled.polls))])
		var image: (data: String, mimeType: String)?
		if matched {
			result.set("match", polled.last!.observation)
			if until == "element_appears" {
				let confirmed = await confirm()
				result.set("inspection", confirmed.inspection)
				image = confirmed.image
			}
		} else {
			result.set("last_observation", polled.last?.observation ?? .null)
			if let error = polled.lastError { result.set("last_error", JSON(error)) }
		}
		return (matched, result, image)
	}

	/// Inspects once after an element appears, so the result carries a snapshot that action tools accept.
	private func confirm() async -> (inspection: JSON, image: (data: String, mimeType: String)?) {
		do {
			let (data, image) = try await Tools.observation(pid: pid!, windowID: window!)
			let match = element!
			let elements = (data["ui_elements"]?.array ?? []).filter { element in
				let attributes = element["attributes"]
				return (element["role"]?.string == match["role"]?.string || attributes?["role"]?.string == match["role"]?.string)
					&& (match["title"] == nil || element["label"]?.string == match["title"]?.string || attributes?["title"]?.string == match["title"]?.string)
					&& (match["value"] == nil || element["value"]?.string == match["value"]?.string)
					&& (match["identifier"] == nil || attributes?["identifier"]?.string == match["identifier"]?.string)
			}
			return (.object([
				"snapshot_id": elements.isEmpty ? .null : data["snapshot_id"],
				"window_title": data["window_title"],
				"elements": .array(Array(elements.prefix(maxRows))),
				"note": elements.isEmpty ? "The element is not among this inspection's elements, which stop at its first 200. Inspect again with a scope that contains it to act on it." : nil,
			]), elements.isEmpty ? nil : image)
		} catch {
			return (.object([("snapshot_id", .null), ("error", JSON((error as? ToolError)?.message ?? String(describing: error)))]), nil)
		}
	}

	func note(matched: Bool) -> String {
		if !matched { return "The condition did not hold before the timeout. Nothing was sent; observe again before acting, or wait again." }
		if until == "element_appears" {
			return "inspection.snapshot_id and the listed element IDs come from one inspection taken after the match and work with click and the other action tools. When it is null, inspect before acting."
		}
		if until == "window_appears" {
			return "Each window's target and window_id work as desktop_windows rows do; pass pid and window_id to desktop_inspect before input."
		}
		return "The condition held at the last poll and may change afterward; inspect before acting."
	}
}

private struct DeadlinePassed: Error {}

/// Runs one read, abandoning it when the deadline passes first.
private func withDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask { try await work() }
		group.addTask {
			try await Task.sleep(until: deadline)
			throw DeadlinePassed()
		}
		defer { group.cancelAll() }
		return try await group.next()!
	}
}

extension Tools {
	static func wait(_ arguments: JSON) async throws -> ToolResult {
		let condition = try WaitCondition(arguments)
		let (matched, result, image) = await condition.report(try await condition.poll())
		var data = result
		data.set("note", JSON(condition.note(matched: matched)))
		return ToolResult(text: data.text, image: image)
	}
}

extension Tools {
	/// The condition an action's expect names: desktop_wait's arguments without op, with a shorter timeout.
	static func expectation(_ arguments: JSON) throws -> WaitCondition? {
		guard let expect = arguments["expect"] else { return nil }
		guard case .object = expect else { throw ToolError("expect must be an object naming a desktop_wait condition with until.") }
		if expect["op"] != nil { throw ToolError("expect takes desktop_wait's arguments without op.") }
		return try WaitCondition(expect, maxTimeout: expectMax, defaultTimeout: expectDefault)
	}

	/// Runs an action once, and when its outcome is unknown, polls the expected condition briefly. The condition
	/// must not hold before input, so a later match shows the input's effect. Input is never repeated.
	static func expectAfter(_ expect: WaitCondition, _ act: () async throws -> ToolResult) async throws -> ToolResult {
		func refused(_ reason: String, _ observation: JSON) -> ToolResult {
			let action: JSON = .object([("outcome", "refused"), ("reason", JSON(reason)), ("message", "No input was sent.")])
			var text = JSON.object([("action", action), ("expectation", .object([("until", JSON(expect.until)), ("status", "refused"), ("before", observation)]))]).text
			if text.utf8.count > maxText { text = JSON.object([("action", action)]).text }
			return ToolResult(text: text, outcome: "refused", isError: true)
		}
		let before: Check
		do { before = try await expect.check() } catch {
			return refused("The expected condition couldn't be read before input: \((error as? ToolError)?.message ?? String(describing: error))", .null)
		}
		if before.holds {
			return refused("The expected condition already holds, so it can't show what this action does. Expect a condition the action changes, or leave out expect.", before.observation)
		}
		if before.observation["error"] != nil {
			return refused("The expected condition couldn't be read reliably before input, so a later match wouldn't show this action's effect. Fix the condition, or leave out expect.", before.observation)
		}
		let result = try await act()
		guard result.outcome == "unknown" else { return result }
		var data = (try? JSON(parsing: result.text)) ?? .object([])
		var expectation: JSON
		var image: (data: String, mimeType: String)?
		var matched = false
		do {
			(matched, expectation, image) = await expect.report(try await expect.poll())
		} catch {
			// Stopping ends the check, not the input already sent; the outcome stays unknown.
			expectation = .object([("until", JSON(expect.until)), ("status", "interrupted")])
		}
		if matched {
			expectation.set("note", "The condition did not hold before input and held after it, so the outcome is completed. It may change afterward; inspect before acting.")
			var action = data["action"] ?? .object([])
			action.set("outcome", "completed")
			action.set("native_outcome", "unknown")
			data.set("action", action)
		} else if expectation["status"]?.string != "interrupted" {
			expectation.set("note", "The condition did not hold before the timeout, so the outcome stays unknown. The input was not repeated; observe before acting again.")
		}
		var whole = data
		whole.set("expectation", expectation)
		var text = whole.text
		if text.utf8.count > maxText {
			var kept = expectation
			for key in ["match", "last_observation"] { kept.set(key, nil) }
			if let inspection = expectation["inspection"] { kept.set("inspection", .object([("snapshot_id", inspection["snapshot_id"] ?? .null)])) }
			kept.set("omitted", "The observation exceeded the result limit; inspect to see it.")
			whole.set("expectation", kept)
			text = whole.text
		}
		let outcome = matched ? "completed" : "unknown"
		return ToolResult(text: text, outcome: outcome, image: matched ? image : nil, isError: !matched)
	}
}
