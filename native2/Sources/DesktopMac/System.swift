import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import DesktopProtocol

/// The focused element read waits this long at most, so a slow app never delays the inventory.
private let focusReadLimit: Duration = .milliseconds(300)

private let accents: [Int: String] = [-1: "graphite", 0: "red", 1: "orange", 2: "yellow", 3: "green", 4: "blue", 5: "purple", 6: "pink"]

extension Mac {
	/// Desktop-wide state an agent reads before acting: where input would land, appearance, session and input.
	static func systemState() async -> JSON {
		let (front, appearance) = await MainActor.run { () -> ((pid: pid_t, bundle: String?, name: String?)?, JSON) in
			let app = NSWorkspace.shared.frontmostApplication
			let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			let defaults = UserDefaults.standard
			let accent = defaults.object(forKey: "AppleAccentColor") == nil ? "multicolor" : accents[defaults.integer(forKey: "AppleAccentColor")]
			let workspace = NSWorkspace.shared
			let appearance: JSON = .object([
				"mode": JSON(dark ? "dark" : "light"),
				"switches_automatically": JSON(defaults.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically")),
				"accent_color": accent.map(JSON.string),
				"increase_contrast": JSON(workspace.accessibilityDisplayShouldIncreaseContrast),
				"reduce_motion": JSON(workspace.accessibilityDisplayShouldReduceMotion),
				"reduce_transparency": JSON(workspace.accessibilityDisplayShouldReduceTransparency),
				"invert_colors": JSON(workspace.accessibilityDisplayShouldInvertColors),
				"differentiate_without_color": JSON(workspace.accessibilityDisplayShouldDifferentiateWithoutColor),
			])
			return (app.map { ($0.processIdentifier, $0.bundleIdentifier, $0.localizedName) }, appearance)
		}

		var warnings: [String] = []
		var element: JSON?
		if let pid = front?.pid {
			switch await withDeadline(focusReadLimit, { focusedElement(pid) }) {
			case .some(.some(let read)): element = read
			case .some(.none): warnings.append("The focused element could not be read through Accessibility, so focus.element is unknown.")
			case .none: warnings.append("The focused element read took longer than 300 ms, so focus.element is unknown.")
			}
		}
		let frontWindow = front.flatMap { front in normalWindows([.optionOnScreenOnly, .excludeDesktopElements]).first { $0.pid == front.pid }?.id }
		let focus: JSON = .object([
			"pid": front.map { JSON($0.pid) },
			"bundle_id": front?.bundle.map(JSON.string),
			"app_name": front?.name.map(JSON.string),
			"window_id": (frontWindow ?? element?["window_id"]?.int).map { JSON($0) },
			"element": element,
		])

		let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
		var online = [CGDirectDisplayID](repeating: 0, count: 16)
		var count: UInt32 = 0
		let asleep = CGGetOnlineDisplayList(16, &online, &count) == .success && count > 0
			&& online.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
		let screensaver = await MainActor.run {
			NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
		}

		var layout: JSON?
		if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
		   let id = tisString(source, kTISPropertyInputSourceID)
		{
			layout = .object(["id": JSON(id), "name": tisString(source, kTISPropertyLocalizedName).map(JSON.string)])
		}
		let pointer = CGEvent(source: nil).map(\.location).map { point -> JSON in
			.object(["x": JSON(Double(point.x)), "y": JSON(Double(point.y)), "display_index": WindowPlaces().pointerDisplay(point).map { JSON($0) }])
		}

		return .object([
			"focus": focus,
			"appearance": appearance,
			"session": .object([
				"locked": JSON(session["CGSSessionScreenIsLocked"] as? Bool == true),
				"on_console": JSON(session["kCGSSessionOnConsoleKey"] as? Bool ?? false),
				"screensaver_running": JSON(screensaver),
				"displays_asleep": JSON(asleep),
				"secure_keyboard_entry": JSON(IsSecureEventInputEnabled()),
			]),
			"input": .object(["keyboard_layout": layout, "pointer": pointer]),
			"menu_bar_autohides": JSON(UserDefaults.standard.bool(forKey: "_HIHideMenuBar")),
			"dock_autohides": JSON(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false),
			"warnings": .array(warnings.map(JSON.string)),
			"note": "Read when this inventory was taken. focus is where keyboard input to the frontmost app would land; element omits the control's value, so read text with desktop_read. Positions are global desktop points.",
		])
	}

	/// The frontmost app's focused element without its value; nil when Accessibility can't read it.
	static func focusedElement(_ pid: pid_t) -> JSON?? {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 0.25)
		var value: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
		if error == .noValue { return .some(nil) }
		guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		let element = value as! AXUIElement
		AXUIElementSetMessagingTimeout(element, 0.05)
		let frame = AX.frame(element) ?? .zero
		return .some(.object([
			"role": JSON(AX.string(element, kAXRoleAttribute) ?? "Unknown"),
			"title": AX.string(element, kAXTitleAttribute).map(JSON.string),
			"identifier": AX.string(element, kAXIdentifierAttribute).map(JSON.string),
			"bounds": bounds(frame),
			"window_id": AX.owningWindowID(element, pid: pid).map { JSON($0) },
		]))
	}
}

private func tisString(_ source: TISInputSource, _ key: CFString) -> String? {
	guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
	return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func bounds(_ rect: CGRect) -> JSON {
	.object([("x", JSON(Double(rect.origin.x))), ("y", JSON(Double(rect.origin.y))), ("width", JSON(Double(rect.width))), ("height", JSON(Double(rect.height)))])
}

/// Normal-level windows front to back, excluding this process's own.
func normalWindows(_ options: CGWindowListOption) -> [(pid: pid_t, id: Int, bounds: CGRect)] {
	let own = getpid()
	let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
	return list.compactMap { info in
		guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0, pid != own,
		      let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, id > 0,
		      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
		      let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
		      bounds.width > 1, bounds.height > 1
		else { return nil }
		return (pid, id, bounds)
	}
}

/// Runs a blocking read off the cooperative pool and gives up waiting after `limit`; nil means it ran out of time.
func withDeadline<T: Sendable>(_ limit: Duration, _ read: @escaping @Sendable () -> T) async -> T? {
	await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
		let once = Once()
		Thread.detachNewThread {
			let value = read()
			if once.claim() { continuation.resume(returning: value) }
		}
		Task {
			try? await Task.sleep(for: limit)
			if once.claim() { continuation.resume(returning: nil) }
		}
	}
}

private final class Once: @unchecked Sendable {
	private let lock = NSLock()
	private var done = false
	func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
