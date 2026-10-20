import DesktopCore
import DesktopMac
import DesktopProtocol

extension Tools {
	/// desktop_spaces: WindowServer's Spaces per display, read-only. Node drops arguments the tool doesn't declare,
	/// and it declares none, so there is nothing to check.
	static func spaces(_: JSON) async throws -> ToolResult {
		ToolResult(text: try bounded(try await Mac.spaces(), field: "displays"))
	}
}
