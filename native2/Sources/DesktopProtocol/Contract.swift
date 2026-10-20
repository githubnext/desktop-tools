import Foundation

/// The MCP contract snapshotted from the Node server by scripts/contract.mjs: tool schemas and server
/// instructions, served unchanged until the Swift side owns them.
public enum Contract {
	public static let instructions: String = instructionsText.trimmingCharacters(in: .newlines)

	/// tools/list's `tools`, in order.
	public static let tools: JSON = try! JSON(parsing: Data(toolsText.utf8))

	/// Tool names whose annotations say they change state; the MCP server runs these one at a time.
	public static let actions: Set<String> = Set((tools.array ?? []).compactMap { tool in
		tool["annotations"]?["readOnlyHint"]?.bool == false ? tool["name"]?.string : nil
	})

	public static let names: Set<String> = Set((tools.array ?? []).compactMap { $0["name"]?.string })
}
