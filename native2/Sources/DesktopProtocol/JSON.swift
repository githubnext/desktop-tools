import Foundation

/// A JSON value whose objects keep their key order, written exactly as JavaScript's `JSON.stringify` would,
/// so result limits measure the same bytes the Node server did.
public enum JSON: Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSON])
	case object([(String, JSON)])

	public static func == (a: JSON, b: JSON) -> Bool {
		switch (a, b) {
		case (.null, .null): true
		case let (.bool(x), .bool(y)): x == y
		case let (.number(x), .number(y)): x == y
		case let (.string(x), .string(y)): x == y
		case let (.array(x), .array(y)): x == y
		case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
		default: false
		}
	}

	public subscript(key: String) -> JSON? {
		guard case let .object(fields) = self else { return nil }
		return fields.last { $0.0 == key }?.1
	}

	/// Sets or appends `key`, keeping its place when it exists.
	public mutating func set(_ key: String, _ value: JSON?) {
		guard case var .object(fields) = self else { return }
		if let index = fields.firstIndex(where: { $0.0 == key }) {
			if let value { fields[index].1 = value } else { fields.remove(at: index) }
		} else if let value {
			fields.append((key, value))
		}
		self = .object(fields)
	}

	public var string: String? { if case let .string(s) = self { s } else { nil } }
	public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
	public var number: Double? { if case let .number(n) = self { n } else { nil } }
	public var array: [JSON]? { if case let .array(a) = self { a } else { nil } }
	public var pairs: [(String, JSON)]? { if case let .object(o) = self { o } else { nil } }
	public var keys: [String]? { pairs?.map(\.0) }
	public var isNull: Bool { if case .null = self { true } else { false } }
	/// An exact integer, as JavaScript's `Number.isSafeInteger` accepts.
	public var int: Int? {
		guard case let .number(n) = self, n.rounded() == n, abs(n) <= 9_007_199_254_740_991 else { return nil }
		return Int(n)
	}
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
	ExpressibleByFloatLiteral, ExpressibleByArrayLiteral
{
	public init(stringLiteral value: String) { self = .string(value) }
	public init(booleanLiteral value: Bool) { self = .bool(value) }
	public init(integerLiteral value: Int) { self = .number(Double(value)) }
	public init(floatLiteral value: Double) { self = .number(value) }
	public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON {
	public init<T: BinaryInteger>(_ value: T) { self = .number(Double(value)) }
	public init(_ value: Double) { self = .number(value) }
	public init(_ value: String) { self = .string(value) }
	public init(_ value: Bool) { self = .bool(value) }
	/// Absent optionals become null; build objects with `object` to omit them instead.
	public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
	public init(_ value: Bool?) { self = value.map(JSON.bool) ?? .null }

	/// An object without the fields whose value is nil, as `JSONEncoder` omits absent optionals.
	public static func object(_ fields: KeyValuePairs<String, JSON?>) -> JSON {
		.object(fields.compactMap { key, value in value.map { (key, $0) } })
	}
}

// MARK: - Writing

extension JSON {
	/// Compact text, byte for byte what `JSON.stringify` writes for the same value.
	public var text: String {
		var out = ""
		write(to: &out)
		return out
	}

	public var data: Data { Data(text.utf8) }

	private func write(to out: inout String) {
		switch self {
		case .null: out += "null"
		case let .bool(b): out += b ? "true" : "false"
		case let .number(n): out += JSON.format(n)
		case let .string(s): JSON.quote(s, into: &out)
		case let .array(values):
			out += "["
			for (i, value) in values.enumerated() {
				if i > 0 { out += "," }
				value.write(to: &out)
			}
			out += "]"
		case let .object(fields):
			out += "{"
			for (i, (key, value)) in fields.enumerated() {
				if i > 0 { out += "," }
				JSON.quote(key, into: &out)
				out += ":"
				value.write(to: &out)
			}
			out += "}"
		}
	}

	static func format(_ n: Double) -> String {
		guard n.isFinite else { return "null" }
		if n.rounded() == n, abs(n) < 1e21 { return String(Int64(n)) }
		return "\(n)"
	}

	static func quote(_ s: String, into out: inout String) {
		out += "\""
		for scalar in s.unicodeScalars {
			switch scalar {
			case "\"": out += "\\\""
			case "\\": out += "\\\\"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			case "\u{08}": out += "\\b"
			case "\u{0C}": out += "\\f"
			case _ where scalar.value < 0x20:
				out += "\\u00" + String(scalar.value, radix: 16).leftPad(2)
			default: out.unicodeScalars.append(scalar)
			}
		}
		out += "\""
	}
}

private extension String {
	func leftPad(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
	public let offset: Int
	public var description: String { "Invalid JSON at byte \(offset)." }
}

extension JSON {
	public init(parsing text: String) throws { try self.init(parsing: Data(text.utf8)) }

	public init(parsing data: Data) throws {
		var parser = Parser(bytes: [UInt8](data))
		parser.skipSpace()
		self = try parser.value()
		parser.skipSpace()
		guard parser.at == parser.bytes.count else { throw JSONParseError(offset: parser.at) }
	}
}

private struct Parser {
	let bytes: [UInt8]
	var at = 0

	init(bytes: [UInt8]) { self.bytes = bytes }

	mutating func skipSpace() {
		while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
	}

	func fail() -> JSONParseError { JSONParseError(offset: at) }

	mutating func expect(_ literal: String) throws {
		for byte in literal.utf8 {
			guard at < bytes.count, bytes[at] == byte else { throw fail() }
			at += 1
		}
	}

	mutating func value() throws -> JSON {
		guard at < bytes.count else { throw fail() }
		switch bytes[at] {
		case UInt8(ascii: "n"): try expect("null"); return .null
		case UInt8(ascii: "t"): try expect("true"); return .bool(true)
		case UInt8(ascii: "f"): try expect("false"); return .bool(false)
		case UInt8(ascii: "\""): return .string(try string())
		case UInt8(ascii: "["):
			at += 1
			var values: [JSON] = []
			skipSpace()
			if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(values) }
			while true {
				skipSpace()
				values.append(try value())
				skipSpace()
				guard at < bytes.count else { throw fail() }
				if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
				guard bytes[at] == UInt8(ascii: "]") else { throw fail() }
				at += 1
				return .array(values)
			}
		case UInt8(ascii: "{"):
			at += 1
			var fields: [(String, JSON)] = []
			skipSpace()
			if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(fields) }
			while true {
				skipSpace()
				guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail() }
				let key = try string()
				skipSpace()
				try expect(":")
				skipSpace()
				fields.append((key, try value()))
				skipSpace()
				guard at < bytes.count else { throw fail() }
				if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
				guard bytes[at] == UInt8(ascii: "}") else { throw fail() }
				at += 1
				return .object(fields)
			}
		default:
			return .number(try number())
		}
	}

	mutating func number() throws -> Double {
		let start = at
		while at < bytes.count, "+-0123456789.eE".utf8.contains(bytes[at]) { at += 1 }
		guard at > start, let text = String(bytes: bytes[start..<at], encoding: .ascii), let n = Double(text) else {
			throw fail()
		}
		return n
	}

	mutating func hex4() throws -> UInt32 {
		guard at + 4 <= bytes.count,
		      let text = String(bytes: bytes[at..<at + 4], encoding: .ascii),
		      let value = UInt32(text, radix: 16)
		else { throw fail() }
		at += 4
		return value
	}

	mutating func string() throws -> String {
		at += 1
		var out = [UInt8]()
		while true {
			guard at < bytes.count else { throw fail() }
			let byte = bytes[at]
			at += 1
			if byte == UInt8(ascii: "\"") { break }
			guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
			guard at < bytes.count else { throw fail() }
			let escape = bytes[at]
			at += 1
			switch escape {
			case UInt8(ascii: "\""): out.append(0x22)
			case UInt8(ascii: "\\"): out.append(0x5C)
			case UInt8(ascii: "/"): out.append(0x2F)
			case UInt8(ascii: "b"): out.append(0x08)
			case UInt8(ascii: "f"): out.append(0x0C)
			case UInt8(ascii: "n"): out.append(0x0A)
			case UInt8(ascii: "r"): out.append(0x0D)
			case UInt8(ascii: "t"): out.append(0x09)
			case UInt8(ascii: "u"):
				var code = try hex4()
				if (0xD800..<0xDC00).contains(code), at + 6 <= bytes.count,
				   bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u")
				{
					let save = at
					at += 2
					let low = try hex4()
					if (0xDC00..<0xE000).contains(low) {
						code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
					} else {
						at = save
					}
				}
				// A lone surrogate becomes U+FFFD, as Swift strings can't hold one.
				out.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
			default: throw fail()
			}
		}
		return String(decoding: out, as: UTF8.self)
	}
}
