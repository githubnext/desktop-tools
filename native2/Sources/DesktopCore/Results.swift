import DesktopProtocol

/// Keeps a result within what an agent can take in at once.
public let maxText = 32_000

public struct ToolError: Error, CustomStringConvertible {
	public let message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// What one tool returns before it becomes MCP content.
public struct ToolResult: Sendable {
	public var text: String
	public var outcome: String?
	public var image: (data: String, mimeType: String)?
	public var isError: Bool

	public init(text: String, outcome: String? = nil, image: (data: String, mimeType: String)? = nil, isError: Bool = false) {
		self.text = text
		self.outcome = outcome
		self.image = image
		self.isError = isError
	}

	/// MCP content: the outcome line first, then the text, then any image.
	public var mcp: JSON {
		var content: [JSON] = [.object([("type", "text"), ("text", JSON(text))])]
		if let outcome { content.insert(.object([("type", "text"), ("text", JSON("Outcome: \(outcome)."))]), at: 0) }
		if let image { content.append(.object([("type", "image"), ("data", JSON(image.data)), ("mimeType", JSON(image.mimeType))])) }
		return .object([("content", .array(content)), ("isError", JSON(isError))])
	}
}

/// Fits `field` within `limit` bytes by dropping its last values, those `keep` accepts only after all others.
public func bounded(_ data: JSON, field: String, limit: Int = maxText, keep: ((JSON) -> Bool)? = nil) throws -> String {
	guard let source = data[field]?.array else { throw ToolError("Native inspection returned no \(field) array.") }
	var values = source
	var value = data
	value.set(field, .array(values))
	var text = value.text
	while text.utf8.count > limit, !values.isEmpty {
		let index = keep.flatMap { keep in values.lastIndex { !keep($0) } } ?? values.count - 1
		values.remove(at: index)
		var shorter = data
		shorter.set(field, .array(values))
		shorter.set("truncated", true)
		shorter.set("omitted", JSON(source.count - values.count))
		text = shorter.text
	}
	guard text.utf8.count <= limit else { throw ToolError("Native inspection metadata exceeds the result limit.") }
	return text
}
