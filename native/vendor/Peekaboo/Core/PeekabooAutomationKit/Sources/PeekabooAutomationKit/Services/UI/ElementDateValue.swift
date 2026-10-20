import Foundation

/// Date and time controls such as NSDatePicker expose an NSDate as AXValue. Requests and readbacks spell
/// it as UTC ISO 8601 to the second, so a readback string matches its request only when the dates agree.
enum ElementDateValue {
    static func date(_ text: String) -> Date? {
        guard let date = self.formatter.date(from: text), self.string(date) == text else { return nil }
        return date
    }

    static func string(_ date: Date) -> String {
        self.formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    private static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
