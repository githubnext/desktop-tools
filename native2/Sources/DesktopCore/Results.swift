import DesktopProtocol

/// Keeps a result within what an agent can take in at once.
public let maxText = 32_000

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

/// Fits `field` within `limit` bytes by dropping its last values, those `keep` accepts only after all others. The
/// limit applies to the compact result a model reads; the text returned stays whole for internal reads.
public func bounded(_ data: JSON, field: String, limit: Int = maxText, keep: ((JSON) -> Bool)? = nil) throws -> String {
	guard let source = data[field]?.array else { throw ToolError("Native inspection returned no \(field) array.") }
	var values = source
	var value = data
	value.set(field, .array(values))
	func size(_ value: JSON) -> Int { compact(value, allWindows: true).text.utf8.count }
	func truncated(_ kept: [JSON]) -> JSON {
		var shorter = data
		shorter.set(field, .array(kept))
		shorter.set("truncated", true)
		shorter.set("omitted", JSON(source.count - kept.count))
		return shorter
	}
	// Without `keep`, dropping from the end keeps the longest prefix that fits, so search for it
	// rather than writing the whole result once per dropped value.
	if keep == nil, size(value) > limit {
		var fits = 0
		var over = values.count
		while over - fits > 1 {
			let mid = (fits + over) / 2
			if size(truncated(Array(values[..<mid]))) <= limit { fits = mid } else { over = mid }
		}
		values = Array(values[..<fits])
		value = truncated(values)
	}
	while size(value) > limit, !values.isEmpty {
		let index = keep.flatMap { keep in values.lastIndex { !keep($0) } } ?? values.count - 1
		values.remove(at: index)
		value = truncated(values)
	}
	guard size(value) <= limit else { throw ToolError("Native inspection metadata exceeds the result limit.") }
	return value.text
}
