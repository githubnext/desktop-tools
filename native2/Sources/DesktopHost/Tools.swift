import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// Runs one MCP tool call in the host, which is the process macOS's grants attach to.
public enum Tools {
	static let actionTools: Set = [
		"desktop_click", "desktop_key", "desktop_type", "desktop_scroll", "desktop_drag", "desktop_hover", "desktop_set_value",
		"desktop_element_action", "desktop_select", "desktop_insert", "desktop_fill_password", "desktop_clipboard_write",
		"desktop_menu", "desktop_dialog_answer", "desktop_menubar_click",
		"desktop_launch", "desktop_open", "desktop_activate", "desktop_hide", "desktop_unhide", "desktop_quit", "desktop_close",
		"desktop_focus", "desktop_minimize", "desktop_restore", "desktop_maximize", "desktop_fullscreen", "desktop_move", "desktop_resize",
	]
	static let expectTools: Set = ["desktop_click", "desktop_key", "desktop_system_key", "desktop_drag", "desktop_insert"]

	/// `client` is the connected MCP binary's pid, which names the caller the user approves.
	public static func call(_ name: String, arguments: JSON, client: pid_t? = nil) async -> ToolResult {
		if let refusal = await admission(name, arguments: arguments, client: client) { return refused(name, refusal) }
		Hooks.admitted()
		// Node checks expect before the action's own arguments.
		if expectTools.contains(name), arguments["expect"] != nil {
			do {
				_ = try expectation(arguments)
			} catch {
				let action: JSON = .object([
					("outcome", "refused"), ("reason", JSON((error as? ToolError)?.message ?? String(describing: error))),
					("message", "No input was sent."),
				])
				return ToolResult(text: JSON.object([("action", action)]).text, outcome: "refused", isError: true)
			}
		}
		do {
			switch name {
			case "desktop_apps": return try await apps(arguments)
			case "desktop_windows": return try await windows(arguments)
			case "desktop_inspect": return try await inspect(arguments)
			case "desktop_click": return try await click(arguments)
			case "desktop_wait": return try await wait(arguments)
			case "desktop_key": return try await key(arguments)
			case "desktop_type": return try await type(arguments)
			case "desktop_scroll": return try await scroll(arguments)
			case "desktop_drag": return try await drag(arguments)
			case "desktop_hover": return try await hover(arguments)
			case "desktop_system_key": return try await systemKey(arguments)
			case "desktop_input_source": return try await inputSource(arguments)
			case "desktop_read": return try await readText(arguments)
			case "desktop_set_value": return try await setValue(arguments)
			case "desktop_set_cell": return try await setCell(arguments)
			case "desktop_element_action": return try await elementAction(arguments)
			case "desktop_select": return try await select(arguments)
			case "desktop_insert": return try await insert(arguments)
			case "desktop_fill_password": return try await fillPassword(arguments)
			case "desktop_clipboard_read": return try await clipboardRead(arguments)
			case "desktop_clipboard_write": return try await clipboardWrite(arguments)
			case "desktop_menus": return try await menus(arguments)
			case "desktop_menu": return try await menu(arguments)
			case "desktop_dialog": return try await dialog(arguments)
			case "desktop_dialog_answer": return try await dialogAnswer(arguments)
			case "desktop_menubar_items": return try await menubarItems(arguments)
			case "desktop_menubar_click": return try await menubarClick(arguments)
			case "desktop_dock": return try await dock(arguments)
			case "desktop_screen": return try await screen(arguments)
			case "desktop_spaces": return try await spaces(arguments)
			case "desktop_notifications": return try await notifications(arguments)
			case "desktop_notification_action": return await notificationAction(arguments)
			case "desktop_launch": return try await launch(arguments, opensItem: false)
			case "desktop_open": return try await launch(arguments, opensItem: true)
			case _ where manageOps[name] != nil: return try await manage(name, arguments)
			default:
				return ToolResult(text: "\(name) isn't in the Swift spike yet.", isError: true)
			}
		} catch let error as ToolError where actionTools.contains(name) {
			// Node checks an action's arguments inside its action runner, so a bad argument is a refused action.
			let action: JSON = .object([
				("outcome", "refused"), ("reason", JSON(error.message)),
				("message", "The desktop action was not sent to the native desktop."),
			])
			return ToolResult(text: JSON.object([("action", action)]).text, outcome: "refused", isError: true)
		} catch let error as ToolError {
			return ToolResult(text: error.message, isError: true)
		} catch {
			return ToolResult(text: String(describing: error), isError: true)
		}
	}

	static func apps(_ arguments: JSON) async throws -> ToolResult {
		var query: String?
		if let value = arguments["query"] {
			guard let text = value.string, text.count <= 256, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				throw ToolError("Application query must contain non-whitespace text and at most 256 characters.")
			}
			query = text.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		var data = try await Mac.apps()
		if let query {
			let apps = data["apps"]?.array ?? []
			let search = query.lowercased()
			let matches = apps.filter { app in
				app["name"]?.string?.lowercased().contains(search) == true
					|| app["bundle_id"]?.string?.lowercased().contains(search) == true
			}
			data.set("apps", .array(matches))
			data.set("filter", .object([
				("query", JSON(query)),
				("fields", ["name", "bundle_id"]),
				("scope", "returned_native_inventory"),
				("total", JSON(apps.count)),
				("matched", JSON(matches.count)),
			]))
		}
		return ToolResult(text: try bounded(data, field: "apps"))
	}

	static func windows(_ arguments: JSON) async throws -> ToolResult {
		guard let pid = arguments["pid"]?.int.flatMap(Int32.init(exactly:)), pid > 0 else {
			throw ToolError("Choose a positive application PID and window ID from the desktop inventory.")
		}
		var data = try await Mac.windows(pid: pid)
		let locked = data["session_locked"]?.bool == true
		let hidden = data["app_hidden"]?.bool
		data.set("windows", .array((data["windows"]?.array ?? []).map { row in
			var row = row
			row.set("availability", windowAvailability(row, sessionLocked: locked, appHidden: hidden))
			return row
		}))
		return ToolResult(text: try bounded(data, field: "windows"))
	}
}
