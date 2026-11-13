import Foundation

/// The MCP contract: the tools declared in ContractTools.swift and the server's instructions, as served for
/// Desktop Tools on this Mac. `desktop-tools-mcp --contract` exports the same declarations for the npm package's /tools.
public enum Contract {
	public static let instructions: String = instructions(app: "Desktop Tools")

	/// Every tool, in order.
	public static let declared: [Tool] = definitions(place: "this Mac", app: "Desktop Tools")

	/// tools/list's `tools`, in order.
	public static let tools: JSON = listed(place: "this Mac", app: "Desktop Tools")

	/// Tool names that change state; the MCP server runs these one at a time.
	public static let actions: Set<String> = Set(declared.filter(\.action).map(\.name))

	/// Tool names whose schema takes `expect`, one desktop_wait condition the input should make true.
	public static let expecting: Set<String> = Set(declared.filter { $0.parameters["properties"]?["expect"] != nil }.map(\.name))

	public static let names: Set<String> = Set(declared.map(\.name))

	/// What /tools exports: each tool with its op and action flag, the shared rules, the server instructions, the
	/// limits and the named keys and wait conditions. `{{place}}` and `{{app}}` stand for where the tools act and the
	/// app that holds the permissions, which each embedder substitutes.
	public static func export() -> JSON {
		let place = "{{place}}", app = "{{app}}"
		let tools: [JSON] = definitions(place: place, app: app).map { tool in
			[
				"name": JSON(tool.name), "op": JSON(tool.op), "action": JSON(tool.action),
				"description": JSON(tool.description), "parameters": tool.parameters,
			]
		}
		return [
			"tools": .array(tools),
			"rules": .array(rules(app: app).map(JSON.string)),
			"instructions": JSON(instructions(app: app)),
			"limits": [
				"tableRowsDefault": JSON(tableRowsDefault), "tableRowsMax": JSON(tableRowsMax),
				"waitDefaultMS": JSON(waitDefaultMS), "waitMaxMS": JSON(waitMaxMS),
				"expectDefaultMS": JSON(expectDefaultMS), "expectMaxMS": JSON(expectMaxMS),
			],
			"waitConditions": .array(waitConditions.map(JSON.string)),
			"keys": .array(keys.map(JSON.string)),
			"systemKeys": .array(systemKeys.map(JSON.string)),
		]
	}
}
