/// A refusal or failure whose message becomes the tool result's text as written.
public struct ToolError: Error, CustomStringConvertible {
	public let message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}
