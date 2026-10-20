import ApplicationServices
import Foundation

/// A native text selection or caret, measured in UTF-16 code units.
public struct TextSelectionRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init?(location: Int, length: Int) {
        guard location >= 0, length >= 0, location != NSNotFound, length != NSNotFound,
              !location.addingReportingOverflow(length).overflow
        else { return nil }
        self.location = location
        self.length = length
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let location = try values.decode(Int.self, forKey: .location)
        let length = try values.decode(Int.self, forKey: .length)
        guard let range = Self(location: location, length: length) else {
            throw DecodingError.dataCorruptedError(
                forKey: .location,
                in: values,
                debugDescription: "Invalid UTF-16 selection range")
        }
        self = range
    }

    init?(nativeValue: CFTypeRef?) {
        guard let nativeValue, CFGetTypeID(nativeValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(nativeValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        self.init(location: range.location, length: range.length)
    }

    /// Whether a native range says the text has neither a selection nor a caret: read-only text, such as a PDF page in
    /// Preview, reports location NSNotFound until something is selected.
    static func isAbsent(nativeValue: CFTypeRef?) -> Bool {
        guard let nativeValue, CFGetTypeID(nativeValue) == AXValueGetTypeID() else { return false }
        let value = unsafeDowncast(nativeValue, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return false }
        return (range.location == NSNotFound || range.location == kCFNotFound) && range.length == 0
    }

    var nativeRange: CFRange {
        CFRange(location: self.location, length: self.length)
    }

    private enum CodingKeys: String, CodingKey {
        case location, length
    }
}
