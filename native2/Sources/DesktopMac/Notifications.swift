import ApplicationServices
import Darwin
import Foundation

// Ported from Peekaboo's NotificationCenterCustomActions (MIT). Since macOS 11, Notification Center's banners and
// entries advertise custom actions as descriptors such as `Name:Close\nTarget:0x0\nSelector:(null)`: Close, Show,
// Options and the posting app's own actions. Only that one process's names are listed or performed, because
// elsewhere a descriptor is arbitrary app text. Built against the macOS 11–15 structure.
enum CustomActions {
	static let executablePath = "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
	static let maxNames = 8
	static let maxNameLength = 64

	/// Whether the process runs Notification Center's executable; a process that cannot be read is not it.
	static func isNotificationCenter(_ pid: pid_t) -> Bool {
		guard pid > 0 else { return false }
		var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
		let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
		guard length > 0 else { return false }
		return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) == executablePath
	}

	/// The name of a `Name:` descriptor, or nil for a standard action or a descriptor without a name line.
	static func name(of descriptor: String) -> String? {
		let first = descriptor.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
		guard first.hasPrefix("Name:") else { return nil }
		return String(first.dropFirst("Name:".count))
	}

	static func isListableName(_ name: String) -> Bool {
		!name.isEmpty && name.count <= maxNameLength && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
	}

	/// The listable names, in advertised order, bounded. A name advertised more than once is never listed,
	/// so each listed name selects exactly one descriptor.
	static func listedNames(_ actions: [String]) -> [String] {
		let names = actions.compactMap(name(of:))
		var counts: [String: Int] = [:]
		for name in names { counts[name, default: 0] += 1 }
		return Array(names.filter { counts[$0] == 1 && isListableName($0) }.prefix(maxNames))
	}

	/// The listed names as one attribute value, or nil when there are none.
	static func attribute(_ actions: [String]) -> String? {
		let names = listedNames(actions)
		return names.isEmpty ? nil : names.joined(separator: "\n")
	}
}

extension Mac {
	/// Performs the one custom action listed under `name` on a Notification Center element.
	public static func performCustomAction(_ element: AXUIElement, id: String, named name: String, window: ClickWindow) throws -> Delivery {
		AXUIElementSetMessagingTimeout(element, 1)
		var raw: CFArray?
		let error = AXUIElementCopyActionNames(element, &raw)
		if error == .invalidUIElement { throw Refusal("ELEMENT_NOT_FOUND", "The element is gone from the window. Inspect it again.") }
		let actions = raw as? [String] ?? []
		guard CustomActions.listedNames(actions).contains(name), let descriptor = actions.first(where: { CustomActions.name(of: $0) == name }) else {
			let listed = CustomActions.listedNames(actions)
			// Peekaboo's unsupportedActionMessage, naming the element by its snapshot ID as the caller passed it.
			var refusal = Refusal(
				"INVALID_INPUT",
				"Action 'AXCustomAction:\(name)' is not supported by \(id). Available actions: \(listed.isEmpty ? "none advertised" : listed.joined(separator: ", "))."
			)
			refusal.reason = "invalid_request"
			throw refusal
		}
		try window.check()
		switch AXUIElementPerformAction(element, descriptor as CFString) {
		case .success: return .accepted("accessibility_action")
		case .invalidUIElement: throw Refusal("ELEMENT_NOT_FOUND", "The element is gone from the window. Inspect it again.")
		default:
			// The app may have acted and then failed to reply in time.
			return Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: 1)
		}
	}
}
