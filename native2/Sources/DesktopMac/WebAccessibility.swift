import AppKit
import ApplicationServices
import Foundation

// Ported from Peekaboo's WebAccessibilityActivation (MIT) and the native client's webaccessibility.swift.

/// What turning on an app's web Accessibility tree did: Chromium and Electron build their web content's tree only
/// once an assistive client asks, so until then a web view lists few or no elements.
public enum WebAccessibilityChange: String, Sendable {
	case enabled, already_on, unsupported, unknown
}

/// The attribute a read turned it on with: Chrome 155 rejects AXManualAccessibility, so apps that ship Chromium
/// fall back to AXEnhancedUserInterface.
public enum WebAccessibilityVia: String, Sendable {
	case manual, enhanced_ui
}

private struct Generation: Hashable {
	let pid: pid_t
	let start: UInt64
}

/// App generations this host already turned it on for, or found it on; it is set at most once per launch.
nonisolated(unsafe) private var enabledGenerations: Set<Generation> = []
private let enabledLock = NSLock()

extension Mac {
	/// Turns it on for the app's current generation. AXEnhancedUserInterface can change how other apps animate and
	/// place windows, so it is tried only when `chromium` allows it and only after AXManualAccessibility was rejected.
	public static func enableWebAccessibility(pid: pid_t, chromium: Bool) -> (change: WebAccessibilityChange, via: WebAccessibilityVia?) {
		guard let start = generation(pid) else { return (.unknown, nil) }
		let key = Generation(pid: pid, start: start)
		enabledLock.lock()
		defer { enabledLock.unlock() }
		if enabledGenerations.contains(key) { return (.already_on, nil) }
		let application = AXUIElementCreateApplication(pid)
		// A busy renderer must not hold the read for the default six seconds.
		AXUIElementSetMessagingTimeout(application, 1)
		func isOn(_ attribute: String) -> Bool { (AX.value(application, attribute) as? Bool) == true }
		if isOn("AXManualAccessibility") || isOn("AXEnhancedUserInterface") {
			enabledGenerations.insert(key)
			return (.already_on, nil)
		}
		switch AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) {
		case .success:
			enabledGenerations.insert(key)
			return (.enabled, .manual)
		case .attributeUnsupported, .notImplemented, .illegalArgument, .actionUnsupported:
			guard chromium else { return (.unsupported, nil) }
			// Chrome reports an error for this set even when it applies it, so only the readback counts.
			_ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
			guard isOn("AXEnhancedUserInterface") else { return (.unsupported, nil) }
			enabledGenerations.insert(key)
			return (.enabled, .enhanced_ui)
		default:
			return (.unknown, nil)
		}
	}

	/// Whether the app's bundle ships Chromium: an Electron or Chromium Embedded framework, or a framework with
	/// Chromium's crash handler among its helpers, as Chrome, Edge and other Chromium-based apps have.
	public static func shipsChromium(_ pid: pid_t) -> Bool {
		guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
		let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
		let files = FileManager.default
		guard let names = try? files.contentsOfDirectory(atPath: frameworks.path) else { return false }
		return names.contains { name in
			guard name.hasSuffix(".framework") else { return false }
			if name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework" { return true }
			let helpers = frameworks.appendingPathComponent(name).appendingPathComponent("Versions/Current/Helpers")
			return (try? files.contentsOfDirectory(atPath: helpers.path))?.contains { $0.hasSuffix("crashpad_handler") } == true
		}
	}
}
