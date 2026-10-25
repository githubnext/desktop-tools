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

/// Fits `field` within `limit` bytes by dropping its last values, those `keep` accepts only after all others. With
/// `dropFirst`, the values its predicate accepts go before any others, and how many went is added to its count
/// field. The limit applies to the compact result a model reads; the text returned stays whole for internal reads.
public func bounded(
	_ data: JSON, field: String, limit: Int = maxText, dropFirst: (predicate: (JSON) -> Bool, count: String)? = nil,
	keep: ((JSON) -> Bool)? = nil
) throws -> String {
	guard let source = data[field]?.array else { throw ToolError("Native inspection returned no \(field) array.") }
	func size(_ value: JSON) -> Int { compact(value, allWindows: true).text.utf8.count }
	guard size(data) > limit else { return data.text }
	// The order values are dropped in: by tier, and within a tier from the end.
	let tier = { (value: JSON) -> Int in
		(dropFirst?.predicate(value) == true ? 0 : 2) + (keep?(value) == true ? 1 : 0)
	}
	let tiers = source.map(tier)
	let order = source.indices.sorted { tiers[$0] != tiers[$1] ? tiers[$0] < tiers[$1] : $0 > $1 }
	func truncated(dropping count: Int) -> JSON {
		let dropped = Set(order.prefix(count))
		var shorter = data
		shorter.set(field, .array(source.indices.filter { !dropped.contains($0) }.map { source[$0] }))
		shorter.set("truncated", true)
		shorter.set("omitted", JSON(count))
		if let dropFirst {
			let first = order.prefix(count).filter { tiers[$0] < 2 }.count
			if first > 0 { shorter.set(dropFirst.count, JSON((data[dropFirst.count]?.int ?? 0) + first)) }
		}
		return shorter
	}
	// Dropping more never grows the result, so search for the fewest drops that fit.
	guard size(truncated(dropping: source.count)) <= limit else { throw ToolError("Native inspection metadata exceeds the result limit.") }
	var fits = source.count, over = 0
	while fits - over > 1 {
		let mid = (fits + over) / 2
		if size(truncated(dropping: mid)) <= limit { fits = mid } else { over = mid }
	}
	return truncated(dropping: fits).text
}
