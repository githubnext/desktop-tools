import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// Runs one MCP tool call in the host, which is the process macOS's grants attach to.
public enum Tools {
	public static func call(_ name: String, arguments: JSON) async -> ToolResult {
		do {
			switch name {
			case "desktop_apps": return try await apps(arguments)
			case "desktop_windows": return try await windows(arguments)
			case "desktop_inspect": return try await inspect(arguments)
			default:
				return ToolResult(text: "\(name) isn't in the Swift spike yet.", isError: true)
			}
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
