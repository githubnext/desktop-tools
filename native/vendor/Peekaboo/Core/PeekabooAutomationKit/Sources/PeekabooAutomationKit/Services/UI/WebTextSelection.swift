import ApplicationServices
import Foundation

/// WebKit's and Chromium's text markers for one element's text, read through its web area.
/// Markers are opaque values that only the web area that issued them can interpret.
@MainActor
protocol WebTextMarkerAccess {
    /// The element's own text, with the markers at its start and end.
    func span() -> WebTextSpan?
    func marker(atIndex index: Int) -> CFTypeRef?
    func index(of marker: CFTypeRef) -> Int?
    func next(after marker: CFTypeRef) -> CFTypeRef?
    func range(from start: CFTypeRef, to end: CFTypeRef) -> CFTypeRef?
    func string(for range: CFTypeRef) -> String?
    func bounds(of range: CFTypeRef) -> (start: CFTypeRef, end: CFTypeRef)?
    func selectedRange() -> CFTypeRef?
    func select(_ range: CFTypeRef) -> Bool
}

struct WebTextSpan {
    let text: String
    let start: CFTypeRef
    let end: CFTypeRef
}

/// Maps a UTF-16 range of an element's text onto markers, and reads a selection back as that range.
@MainActor
enum WebTextSelectionPlanner {
    /// Marker stepping is a fallback for engines whose index markers disagree with the text; it stops at
    /// whichever limit comes first, so a long page never walks its whole text.
    static let maximumSteps = 2048
    static let stepTimeBudget: Duration = .milliseconds(300)

    static func locate(
        _ range: TextSelectionRange,
        in span: WebTextSpan,
        markers: any WebTextMarkerAccess) -> CFTypeRef?
    {
        // An engine can answer NSNotFound for a marker's index; stepping below doesn't need one.
        if let base = markers.index(of: span.start), (0...Int(Int32.max)).contains(base),
           let start = markers.marker(atIndex: base + range.location),
           let end = markers.marker(atIndex: base + range.location + range.length),
           let candidate = markers.range(from: start, to: end),
           self.covers(candidate, start: start, end: end, range: range, in: span, markers: markers)
        {
            return candidate
        }
        // One marker step moves one character as the engine counts it; the readback below decides.
        let text = span.text.utf16
        guard let prefix = String(text.prefix(range.location)),
              let selected = String(text.dropFirst(range.location).prefix(range.length))
        else { return nil }
        let startSteps = prefix.count
        let endSteps = startSteps + selected.count
        guard endSteps <= self.maximumSteps else { return nil }
        let deadline = ContinuousClock.now.advanced(by: self.stepTimeBudget)
        var current = span.start
        var start: CFTypeRef? = startSteps == 0 ? current : nil
        var step = 0
        while step < endSteps {
            guard ContinuousClock.now < deadline, let next = markers.next(after: current) else { return nil }
            current = next
            step += 1
            if step == startSteps { start = current }
        }
        guard let start, let candidate = markers.range(from: start, to: current),
              self.covers(candidate, start: start, end: current, range: range, in: span, markers: markers)
        else { return nil }
        return candidate
    }

    /// Whether the web area's selection is exactly this range of the element's text.
    static func selectionMatches(
        _ range: TextSelectionRange,
        in span: WebTextSpan,
        markers: any WebTextMarkerAccess) -> Bool
    {
        guard let selected = markers.selectedRange(), let bounds = markers.bounds(of: selected) else { return false }
        return self.covers(selected, start: bounds.start, end: bounds.end, range: range, in: span, markers: markers)
    }

    /// The marker range holds the requested text, with exactly the text before and after it in the element on
    /// either side, so it can be neither another occurrence nor a range reaching outside the element.
    private static func covers(
        _ candidate: CFTypeRef,
        start: CFTypeRef,
        end: CFTypeRef,
        range: TextSelectionRange,
        in span: WebTextSpan,
        markers: any WebTextMarkerAccess) -> Bool
    {
        let text = span.text.utf16
        let total = text.count
        guard range.location + range.length <= total,
              let selected = markers.string(for: candidate),
              selected.utf16.elementsEqual(text.dropFirst(range.location).prefix(range.length)),
              let before = markers.range(from: span.start, to: start),
              markers.string(for: before)?.utf16.count == range.location,
              let after = markers.range(from: end, to: span.end),
              markers.string(for: after)?.utf16.count == total - range.location - range.length
        else { return false }
        return true
    }
}

/// Text markers through the element's nearest AXWebArea, with short messaging timeouts.
@MainActor
struct AXWebTextMarkers: WebTextMarkerAccess {
    let webArea: AXUIElement
    let element: AXUIElement

    /// Finds the web area holding element, or nil when its ancestry leaves web content first.
    init?(element: AXUIElement) {
        var current = element
        for _ in 0..<64 {
            AXUIElementSetMessagingTimeout(current, 0.25)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
                  let role = role as? String
            else { return nil }
            if role == "AXWebArea" {
                self.webArea = current
                self.element = element
                return
            }
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { return nil }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    func span() -> WebTextSpan? {
        guard let range = self.copy("AXTextMarkerRangeForUIElement", self.element),
              let text = self.string(for: range),
              let bounds = self.bounds(of: range)
        else { return nil }
        return WebTextSpan(text: text, start: bounds.start, end: bounds.end)
    }

    func marker(atIndex index: Int) -> CFTypeRef? {
        guard index >= 0 else { return nil }
        return self.copy("AXTextMarkerForIndex", NSNumber(value: index))
    }

    func index(of marker: CFTypeRef) -> Int? {
        (self.copy("AXIndexForTextMarker", marker) as? NSNumber)?.intValue
    }

    func next(after marker: CFTypeRef) -> CFTypeRef? {
        self.copy("AXNextTextMarkerForTextMarker", marker)
    }

    func range(from start: CFTypeRef, to end: CFTypeRef) -> CFTypeRef? {
        self.copy("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    }

    func string(for range: CFTypeRef) -> String? {
        self.copy("AXStringForTextMarkerRange", range) as? String
    }

    func bounds(of range: CFTypeRef) -> (start: CFTypeRef, end: CFTypeRef)? {
        // Safari on macOS 27 dropped these parameterized attributes; the range itself still holds both ends.
        if let start = self.copy("AXStartTextMarkerForTextMarkerRange", range),
           let end = self.copy("AXEndTextMarkerForTextMarkerRange", range)
        {
            return (start, end)
        }
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        let markers = unsafeDowncast(range, to: AXTextMarkerRange.self)
        return (AXTextMarkerRangeCopyStartMarker(markers), AXTextMarkerRangeCopyEndMarker(markers))
    }

    func selectedRange() -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self.webArea, "AXSelectedTextMarkerRange" as CFString, &value) == .success
        else { return nil }
        return value
    }

    func select(_ range: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self.webArea, "AXSelectedTextMarkerRange" as CFString, range) == .success
    }

    private func copy(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            self.webArea, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }
}
