import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func copyAXWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Accessibility reads. Each blocks on the target app, so callers bound them with messaging timeouts.
enum AX {
	static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
		return value
	}

	static func string(_ element: AXUIElement, _ attribute: String) -> String? {
		value(element, attribute) as? String
	}

	static func element(_ value: CFTypeRef?) -> AXUIElement? {
		guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		return (value as! AXUIElement)
	}

	static func point(_ value: CFTypeRef?) -> CGPoint? {
		guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		var point = CGPoint.zero
		return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
	}

	static func size(_ value: CFTypeRef?) -> CGSize? {
		guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		var size = CGSize.zero
		return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
	}

	static func frame(_ element: AXUIElement) -> CGRect? {
		guard let origin = point(value(element, kAXPositionAttribute)), let size = size(value(element, kAXSizeAttribute)) else { return nil }
		return CGRect(origin: origin, size: size)
	}

	static func windowID(_ element: AXUIElement) -> Int? { windowIDRead(element).id }

	/// The window number, and whether a failure to read it means Accessibility gave up partway.
	static func windowIDRead(_ element: AXUIElement) -> (id: Int?, incomplete: Bool) {
		var id: CGWindowID = 0
		let error = copyAXWindowID(element, &id)
		guard error == .success, id > 0 else { return (nil, incomplete(error)) }
		return (Int(id), false)
	}

	static func pid(_ element: AXUIElement) -> pid_t? {
		var pid: pid_t = 0
		return AXUIElementGetPid(element, &pid) == .success ? pid : nil
	}

	/// The window an element belongs to: its AXWindow, else the nearest AXWindow ancestor, else its own window number.
	static func owningWindowID(_ element: AXUIElement, pid: pid_t) -> Int? {
		func window(_ candidate: AXUIElement?) -> AXUIElement? {
			guard let candidate, self.pid(candidate) == pid, string(candidate, kAXRoleAttribute) == kAXWindowRole else { return nil }
			AXUIElementSetMessagingTimeout(candidate, 0.05)
			return candidate
		}
		if let owner = window(self.element(value(element, kAXWindowAttribute))), let id = windowID(owner) { return id }
		var current = element
		for _ in 0..<64 {
			guard let parent = self.element(value(current, kAXParentAttribute)) else { break }
			AXUIElementSetMessagingTimeout(parent, 0.05)
			if let owner = window(parent), let id = windowID(owner) { return id }
			current = parent
		}
		return windowID(element)
	}

	/// Errors that mean Accessibility gave up partway rather than that the value doesn't exist.
	static func incomplete(_ error: AXError) -> Bool {
		![.success, .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented].contains(error)
	}

	struct WindowDescriptor {
		let id: Int?
		let title: String
		let bounds: CGRect?
		let isMinimized: Bool?
		let isMain: Bool?
	}

	struct Windows {
		var descriptors: [WindowDescriptor] = []
		var focusedID: Int?
		var reported = 0
		var incomplete = false
		var timedOut = false
	}

	static let windowLimit = 100
	private static let batch = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXMainAttribute, kAXSubroleAttribute]

	/// An app's windows, each read with one batched attribute call, within `budget` seconds.
	static func windows(pid: pid_t, budget: TimeInterval = 2.0) -> Windows {
		let deadline = Date().addingTimeInterval(budget - min(0.25, max(0.01, budget * 0.1)))
		func remaining() -> Float { Float(max(0, deadline.timeIntervalSinceNow)) }
		var result = Windows()
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, min(0.2, remaining()))
		var raw: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
		guard error == .success, let list = raw as? [AXUIElement] else {
			result.incomplete = error == .success || [.attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented].contains(error) || incomplete(error)
			return result
		}
		result.reported = list.count
		var focusedRaw: CFTypeRef?
		let focusError = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRaw)
		if let focused = element(focusedRaw) { result.focusedID = windowID(focused) }
		if incomplete(focusError) { result.incomplete = true }
		if list.count > windowLimit { result.incomplete = true }
		for window in list.prefix(windowLimit) {
			guard remaining() > 0 else {
				result.timedOut = true
				break
			}
			AXUIElementSetMessagingTimeout(window, min(0.2, remaining()))
			guard self.pid(window) == pid else {
				result.incomplete = true
				continue
			}
			var values: CFArray?
			let batchError = AXUIElementCopyMultipleAttributeValues(window, batch as CFArray, [], &values)
			var fields: [CFTypeRef?]
			if batchError == .success, let read = values as? [CFTypeRef], read.count == 6 {
				fields = read.map { $0 }
			} else if [.attributeUnsupported, .notImplemented].contains(batchError) || batchError == .success {
				var reads: [CFTypeRef?] = []
				for attribute in batch {
					var value: CFTypeRef?
					let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &value)
					if incomplete(error) { break }
					reads.append(error == .success ? value : nil)
				}
				guard reads.count == batch.count else {
					result.incomplete = true
					continue
				}
				fields = reads
			} else {
				if incomplete(batchError) { result.incomplete = true }
				continue
			}
			// A batched read reports a failed attribute as an AXValue holding its error.
			var dropped = false
			fields = fields.map { field in
				guard let field, CFGetTypeID(field) == AXValueGetTypeID(), AXValueGetType(field as! AXValue) == .axError else { return field }
				var code = AXError.success
				AXValueGetValue(field as! AXValue, .axError, &code)
				if incomplete(code) { dropped = true }
				return nil
			}
			if dropped {
				result.incomplete = true
				continue
			}
			let origin = point(fields[1])
			let size = size(fields[2])
			// Finder's Desktop has no window number, so like Peekaboo this marks every Finder listing incomplete.
			let id = windowIDRead(window)
			if id.incomplete { result.incomplete = true }
			result.descriptors.append(WindowDescriptor(
				id: id.id,
				title: fields[0] as? String ?? "",
				bounds: origin.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } },
				isMinimized: fields[3] as? Bool,
				isMain: fields[4] as? Bool
			))
		}
		return result
	}
}
