import DesktopCore
import DesktopMac
import DesktopProtocol

extension Tools {
	/// desktop_spaces: WindowServer's Spaces per display, read-only. Node drops arguments the tool doesn't declare,
	/// and it declares none, so there is nothing to check.
	static func spaces(_: JSON) async throws -> ToolResult {
		ToolResult(text: try bounded(try await Mac.spaces(), field: "displays"))
	}

	/// desktop_switch_space: foreground Control-arrow steps to one Space, read back from WindowServer after each.
	static func switchSpace(_ arguments: JSON) async -> ToolResult {
		guard let id = arguments["space_id"]?.int, id >= 1 else {
			let action: JSON = .object([
				("outcome", "refused"), ("reason", "Pass one space_id from a fresh desktop_spaces result."),
				("message", "The desktop action was not sent to the native desktop."),
			])
			return ToolResult(text: JSON.object([("action", action)]).text, outcome: "refused", isError: true)
		}
		let (outcome, action) = await Mac.switchSpace(UInt64(id))
		return ToolResult(text: JSON.object([("action", action)]).text, outcome: outcome, isError: outcome != "completed")
	}
}
