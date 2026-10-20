import Darwin
import Foundation

/// Notification Center's custom accessibility actions.
///
/// Since macOS 11, Notification Center's banners and entries advertise custom actions as descriptors such as
/// `Name:Close\nTarget:0x0\nSelector:(null)`: Close, Show, Options and the posting app's own actions. Only that
/// one process's names are listed or performed, because elsewhere a descriptor is arbitrary app text. Built
/// against the macOS 11–15 structure.
enum NotificationCenterCustomActions {
    static let executablePath = "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
    /// An action name in this form asks for the one custom action listed under that exact name.
    static let actionPrefix = "AXCustomAction:"
    static let maxNames = 8
    static let maxNameLength = 64

    /// Whether the process runs Notification Center's executable; a process that cannot be read is not it.
    static func isNotificationCenter(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == self.executablePath
    }

    /// The element's advertised actions when it belongs to Notification Center, otherwise nil.
    @MainActor
    static func descriptors(of element: AutomationElement, processIdentifier: pid_t) -> [String]? {
        self.isNotificationCenter(processIdentifier) ? element.actionNames : nil
    }

    /// The name of a `Name:` descriptor, or nil for a standard action or a descriptor without a name line.
    static func name(of descriptor: String) -> String? {
        let first = descriptor.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard first.hasPrefix("Name:") else { return nil }
        return String(first.dropFirst("Name:".count))
    }

    /// A name an agent may see and request: non-empty, bounded, with no control characters.
    static func isListableName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= self.maxNameLength
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The listable names, in advertised order, bounded. A name advertised more than once is never listed,
    /// so each listed name selects exactly one descriptor.
    static func listedNames(_ actions: [String]) -> [String] {
        let names = actions.compactMap(self.name(of:))
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        return Array(names.filter { counts[$0] == 1 && self.isListableName($0) }.prefix(self.maxNames))
    }

    /// The listed names as one attribute value, or nil when there are none.
    static func attribute(_ actions: [String]) -> String? {
        let names = self.listedNames(actions)
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }

    /// The listed name an action name in the reserved form requests, or nil when it is not in that form.
    static func requestedName(_ actionName: String) -> String? {
        guard actionName.hasPrefix(self.actionPrefix) else { return nil }
        let name = String(actionName.dropFirst(self.actionPrefix.count))
        return self.isListableName(name) ? name : nil
    }

    /// The one descriptor listed under the exact name, or nil when the name is not listed.
    static func descriptor(named name: String, in actions: [String]) -> String? {
        guard self.listedNames(actions).contains(name) else { return nil }
        return actions.first { self.name(of: $0) == name }
    }
}
