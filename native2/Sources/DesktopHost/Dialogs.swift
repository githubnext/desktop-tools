import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

private let answeredHint = "The dialog may already have been answered. List it again or refresh desktop_windows; do not blindly repeat the answer."
private let unresolved = "The dialog was not resolved to the observed application generation and window. Refresh desktop_apps or desktop_windows and list the dialog again."

/// A dialog's target: an app, or one window of it with the bounds desktop_windows listed.
private struct DialogTarget {
	let pid: pid_t
	let generation: UInt64
	let window: (id: Int, bounds: CGRect, isMinimized: Bool)?

	var receipt: (Int) -> JSON {
		{ id in .object([("pid", JSON(pid)), ("window_id", JSON(id)), ("process_start_identity_decimal", JSON(String(generation)))]) }
	}

	/// Whether the dialog was read in the observed generation and, for a window target, its exact window and bounds.
	func matches(_ read: DialogRead) -> Bool {
		guard read.generation == generation else { return false }
		guard let window else { return true }
		return read.window.id == window.id && read.window.bounds == window.bounds && read.window.isMinimized == window.isMinimized
	}
}

/// Node's validateDialogTarget: a window target when it names a window, else only an app target.
private func dialogTarget(_ value: JSON?) throws -> DialogTarget {
	guard let value, value.pairs != nil, value["window_id"] != nil else {
		let (pid, generation) = try appTargetArgument(value)
		return DialogTarget(pid: pid, generation: generation, window: nil)
	}
	let (pid, generation) = try appTargetArgument(value, only: false)
	let invalid = ToolError("Pass the window's target object, including its original bounds, from desktop_windows unchanged.")
	guard let id = value["window_id"]?.int, (1...4_294_967_295).contains(id), let minimized = value["is_minimized"]?.bool,
	      let bounds = value["bounds"], let x = bounds["x"]?.number, let y = bounds["y"]?.number,
	      let width = bounds["width"]?.number, let height = bounds["height"]?.number,
	      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
	else { throw invalid }
	return DialogTarget(pid: pid, generation: generation, window: (id, CGRect(x: x, y: y, width: width, height: height), minimized))
}

/// The app's windows as desktop_windows lists them, which bound the dialog search.
private func dialogWindows(_ pid: pid_t) async -> [DialogWindow] {
	guard let listing = try? await Mac.windows(pid: pid) else { return [] }
	return (listing["windows"]?.array ?? []).compactMap { row in
		guard let id = row["window_id"]?.int, let bounds = row["bounds"], let x = bounds["x"]?.number, let y = bounds["y"]?.number,
		      let width = bounds["width"]?.number, let height = bounds["height"]?.number
		else { return nil }
		return DialogWindow(id: id, title: row["window_title"]?.string ?? "", bounds: CGRect(x: x, y: y, width: width, height: height),
		                    isMinimized: row["is_minimized"]?.bool ?? false)
	}
}

private func boundsJSON(_ rect: CGRect) -> JSON {
	.object([("x", JSON(Double(rect.origin.x))), ("y", JSON(Double(rect.origin.y))),
	         ("width", JSON(Double(rect.width))), ("height", JSON(Double(rect.height)))])
}

/// Reads the target's dialog; a native refusal reads as the bridge reported it, an unmatched dialog as the client did.
private func readDialog(_ target: DialogTarget) async throws -> DialogRead {
	let windows = await dialogWindows(target.pid)
	let read: DialogRead
	do {
		read = try await run { try Mac.dialog(pid: target.pid, windowID: target.window?.id, windows: windows) }
	} catch let refusal as Refusal {
		throw BridgeError(message: refusal.message)
	}
	guard target.matches(read) else { throw ClientError(message: unresolved) }
	return read
}

/// A failure the Peekaboo bridge reported as an error envelope.
private struct BridgeError: Error { let message: String }
/// A failure the native client reported itself.
private struct ClientError: Error { let message: String }

extension Tools {
	static func dialog(_ arguments: JSON) async throws -> ToolResult {
		let target = try dialogTarget(arguments["target"])
		let read: DialogRead
		do {
			read = try await readDialog(target)
		} catch let error as BridgeError {
			throw ToolError("internalError: \(error.message).")
		} catch let error as ClientError {
			throw ToolError("DESKTOP_ERROR: \(error.message).")
		}
		let data: JSON = .object([
			("target", .object([
				("pid", JSON(target.pid)), ("process_start_identity_decimal", JSON(String(read.generation))), ("window_id", JSON(read.window.id)),
				("bounds", boundsJSON(read.window.bounds)), ("is_minimized", JSON(read.window.isMinimized)),
			])),
			("application_name", JSON(read.applicationName)),
			("window_title", JSON(read.window.title)),
			("dialog", read.dialog),
			("buttons", .array(read.buttons.map { .object([("title", JSON($0.title)), ("is_enabled", JSON($0.isEnabled)), ("is_default", JSON($0.isDefault))]) })),
			("text_fields", .array(read.fields.map { field in
				.object(["index": JSON(field.index), "title": field.title.map(JSON.string), "value": field.value.map(JSON.string),
				         "placeholder": field.placeholder.map(JSON.string), "is_enabled": JSON(field.isEnabled)])
			})),
			("static_texts", .array(read.staticTexts.map(JSON.string))),
			("other_elements", read.others),
			("target_receipt", target.receipt(read.window.id)),
		])
		return ToolResult(text: try bounded(data, field: "other_elements"))
	}

	static func dialogAnswer(_ arguments: JSON) async throws -> ToolResult {
		let button = arguments["button"], field = arguments["field"], text = arguments["text"], path = arguments["path"]
		let press = button != nil && field == nil && text == nil && path == nil
		let enter = button == nil && field != nil && text != nil && path == nil
		let choose = path != nil && button == nil && field == nil && text == nil
		// MCP's exclusive argument check comes before the action runner, so it is a plain error.
		guard press || enter || choose else {
			return ToolResult(text: "Supply one button title, one field index with its text, or one path.", isError: true)
		}
		let target = try dialogTarget(arguments["target"])
		if press {
			guard let title = button?.string, !title.isEmpty, title.utf16.count <= 512 else {
				throw ToolError("Use one exact dialog button title of at most 512 UTF-16 code units.")
			}
		} else if choose {
			guard let path = path?.string, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
				throw ToolError("Use one absolute file-dialog path of at most 4096 bytes.")
			}
		} else {
			guard let index = field?.int, (0...1000).contains(index), let text = text?.string, text.utf16.count <= 8192 else {
				throw ToolError("Answer a dialog with exactly one button title, one listed field index and at most 8192 UTF-16 code units of text, or one path.")
			}
		}

		var action: [(String, JSON)] = [("outcome", "refused"), ("action", "dialog")]
		if let button { action.append(("button", button)) }
		if let field { action.append(("field", field)) }
		if let path { action.append(("path", path)) }
		var receipt: JSON?
		func finish(_ outcome: String, requires: Bool, error: JSON? = nil) async -> ToolResult {
			action[0] = ("outcome", JSON(outcome))
			action.append(("requires_fresh_observation", JSON(requires)))
			if let error { action.append(("error", error)) }
			if let receipt { action.append(("target_receipt", receipt)) }
			let data = JSON.object(action)
			if outcome == "refused" { return await explainRefusal(data, pid: target.pid, windowID: receipt?["window_id"]?.int) }
			if outcome == "completed" || receipt != nil { return await observeAnswer(data, outcome: outcome, pid: target.pid, generation: target.generation) }
			return ToolResult(text: JSON.object([("action", data)]).text, outcome: outcome, isError: true)
		}
		/// A refusal or failure the native service returned with its outcome.
		func failed(_ refusal: Refusal, windowID: Int? = nil) async -> ToolResult {
			action.append(("native_outcome", refusal.outcome))
			if let windowID { receipt = target.receipt(windowID) }
			return await finish("refused", requires: !["operation_unsupported", "invalid_request"].contains(refusal.reason),
			                    error: errorJSON(refusal.code, refusal.message, hint: refusal.hint))
		}
		func unconfirmed(_ failure: DialogUnconfirmed) async -> ToolResult {
			action.append(("native_outcome", failure.delivery.json))
			if let id = failure.windowID { receipt = target.receipt(id) }
			return await finish("unknown", requires: true, error: errorJSON("DESKTOP_ACTION_FAILED", failure.message, hint: answeredHint))
		}
		/// An error without an outcome, which the client reports with its code and message only.
		func plain(_ code: String, _ message: String) async -> ToolResult {
			await finish("refused", requires: false, error: errorJSON(code, message))
		}

		if Mac.sessionLocked {
			return await failed(Refusal("DESKTOP_ACTION_FAILED", "The macOS GUI session is locked. No dialog answer was dispatched.",
			                            hint: "Unlock the active user session, then list the dialog again."))
		}
		guard Mac.isRunning(target.pid, generation: target.generation) else {
			return await plain("DESKTOP_ACTION_FAILED", "The observed application generation could not be attested before answering the dialog. Refresh desktop_apps.")
		}
		// A fresh read binds the requested control to the exact dialog before anything is sent.
		let read: DialogRead
		do {
			read = try await readDialog(target)
		} catch let error as BridgeError {
			return await plain("internalError", error.message)
		} catch let error as ClientError {
			return await plain("DESKTOP_ACTION_FAILED", error.message)
		}
		let windows = await dialogWindows(target.pid)
		let pid = target.pid, windowID = target.window?.id

		if let title = button?.string {
			func normalized(_ title: String) -> String {
				title.trimmingCharacters(in: .whitespacesAndNewlines)
					.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").lowercased()
			}
			let exact = read.buttons.filter { $0.title == title }
			let similar = read.buttons.filter { normalized($0.title) == normalized(title) }
			guard exact.count == 1, similar.count == 1, normalized(title) != "default" else {
				return await failed(Refusal(
					"DESKTOP_ACTION_FAILED",
					exact.isEmpty ? "No dialog button has exactly the title \(String(reflecting: title))." : "The dialog button title \(String(reflecting: title)) is not unique.",
					hint: "Available buttons: \(read.buttons.map { String(reflecting: $0.title) }.joined(separator: ", ")). Use one exact, unique title."))
			}
			guard exact[0].isEnabled else {
				return await failed(Refusal("DESKTOP_ACTION_FAILED", "The dialog button \(String(reflecting: title)) is disabled.",
				                            hint: "List the dialog again after its state changes."))
			}
			do {
				let answer = try await run { try Mac.pressDialogButton(pid: pid, windowID: windowID, windows: windows, title: title) }
				action += [("native_outcome", answer.delivery.json), ("details", .object(answer.details.map { ($0, JSON($1)) }))]
				receipt = target.receipt(answer.windowID)
				return await finish(answer.delivery.state == .confirmedChange ? "completed" : "unknown", requires: true)
			} catch let refusal as Refusal {
				// Preparing the press is its own bridge request, whose refusals arrive as error envelopes.
				return await plain("internalError", refusal.message)
			} catch let failure as DialogUnconfirmed {
				return await unconfirmed(failure)
			}
		}
		if path != nil {
			guard read.isFileDialog else {
				var refusal = Refusal("DESKTOP_ACTION_FAILED", "The dialog is not an Open or Save panel, so it takes no path.",
				                      hint: "Answer it with a button title, or a field index and text.")
				refusal.reason = "operation_unsupported"
				return await failed(refusal)
			}
			// Peekaboo's foreground Go to Folder flow isn't ported to the spike.
			return await plain("DESKTOP_ACTION_FAILED", "The Swift spike does not enter file-dialog paths yet. No path was sent.")
		}
		let index = field!.int!, value = text!.string!
		let fields = read.fields.filter { $0.index == index }
		guard fields.count == 1 else {
			return await failed(Refusal("DESKTOP_ACTION_FAILED", "The dialog has no text field at index \(index).",
			                            hint: "List the dialog and choose one current text field index."))
		}
		guard fields[0].isEnabled else {
			return await failed(Refusal("DESKTOP_ACTION_FAILED", "The dialog text field at index \(index) is disabled.",
			                            hint: "List the dialog again after its state changes."))
		}
		do {
			let answer = try await run { try Mac.enterDialogText(pid: pid, windowID: windowID, windows: windows, field: index, text: value) }
			action += [("native_outcome", answer.delivery.json), ("details", .object(answer.details.map { ($0, JSON($1)) }))]
			receipt = target.receipt(answer.windowID)
			return await finish("completed", requires: answer.delivery.state != .confirmedNoChange)
		} catch let refusal as Refusal {
			return await failed(refusal)
		} catch let refusal as DialogRefusal {
			return await failed(refusal.refusal, windowID: refusal.windowID)
		} catch let failure as DialogUnconfirmed {
			return await unconfirmed(failure)
		}
	}

	/// Node's explainRefusal: a refused action names its window's availability when that explains it.
	static func explainRefusal(_ action: JSON, pid: pid_t, windowID: Int?) async -> ToolResult {
		var action = action
		if let windowID, let listing = try? await Mac.windows(pid: pid) {
			let locked = listing["session_locked"]?.bool == true
			let row = (listing["windows"]?.array ?? []).first { $0["window_id"]?.int == windowID }
			let availability: JSON = row.map { windowAvailability($0, sessionLocked: locked, appHidden: listing["app_hidden"]?.bool) }
				?? (locked ? windowAvailability(.object([]), sessionLocked: true, appHidden: nil)
					: .object([("state", "unavailable"), ("reason", "window_gone"),
					           ("hint", "The window is no longer in its app's window list; it may have closed. List desktop_windows again and choose a current window.")]))
			if availability["state"]?.string != "available" { action.set("target_availability", availability) }
		}
		return ToolResult(text: JSON.object([("action", action)]).text, outcome: "refused", isError: true)
	}

	/// Node's observeManagement for a dialog answer: the app's inventory row and its windows after the answer.
	private static func observeAnswer(_ action: JSON, outcome: String, pid: pid_t, generation: UInt64) async -> ToolResult {
		var data: [(String, JSON)] = [("action", action)]
		func result(_ message: String?, error: String?) -> ToolResult {
			if let error { data += [("observation_error", JSON(error)), ("message", JSON(message ?? ""))] }
			let value = JSON.object(data)
			let text = value["windows"] != nil ? (try? bounded(value, field: "windows")) : value.text
			return ToolResult(text: text ?? JSON.object([("action", action)]).text, outcome: outcome, isError: outcome != "completed")
		}
		let failure = outcome == "completed"
			? "The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly."
			: "Native completion was not confirmed and later inventory was unavailable. Refresh the target before choosing any further action; do not blindly repeat the request."
		guard let apps = try? await Mac.apps() else { return result(failure, error: "Native application inventory is unavailable.") }
		data += [("application_inventory_completeness", apps["inventory_completeness"] ?? .null),
		         ("application_inventory_warnings", apps["inventory_warnings"] ?? .null)]
		let app = (apps["apps"]?.array ?? []).first { $0["pid"]?.int == Int(pid) }
		data.append(("application", app ?? .null))
		// The answer's receipt owns its evidence; a later inventory without the app can't undo it.
		guard let app else { return result(nil, error: nil) }
		guard app["process_start_identity_decimal"]?.string == String(generation) else {
			return result(failure, error: "The application changed process generation after the action.")
		}
		guard let windows = try? await Mac.windows(pid: pid) else { return result(failure, error: "Native window inventory is unavailable.") }
		data += [("window_inventory_completeness", windows["inventory_completeness"] ?? .null),
		         ("window_inventory_warnings", windows["inventory_warnings"] ?? .null),
		         ("windows", windows["windows"] ?? .array([]))]
		return result(nil, error: nil)
	}
}
