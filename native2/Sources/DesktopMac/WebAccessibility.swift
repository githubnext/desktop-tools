import AppKit
import ApplicationServices
import Foundation

// Ported from Peekaboo's WebAccessibilityActivation (MIT) and the native client's webaccessibility.swift.

/// What turning on an app's web Accessibility tree did: Chromium and Electron build their web content's tree only
/// once an assistive client asks, so until then a web view lists few or no elements.
public enum WebAccessibilityChange: String, Sendable {
	case enabled, already_on, unsupported, unknown
	/// This read turned it back off, which this host had turned on (#231).
	case restored
}

/// The attribute a read turned it on with: Chrome 155 rejects AXManualAccessibility, so apps that ship Chromium
/// fall back to AXEnhancedUserInterface.
public enum WebAccessibilityVia: String, Sendable {
	case manual, enhanced_ui
}

struct Generation: Hashable {
	let pid: pid_t
	let start: UInt64
}

/// Which app launches have web accessibility on as far as this host knows, and which of them it turned on itself
/// and so may turn back off (#231). One found on belongs to whoever turned it on, such as VoiceOver, and is never
/// turned off.
struct WebAccessibilityLedger {
	/// Launches this host turned it on for, or found it on; it is set at most once per launch.
	private(set) var on: Set<Generation> = []
	/// The attribute this host set, and when a read last relied on it.
	private(set) var owned: [Generation: (via: WebAccessibilityVia, used: ContinuousClock.Instant)] = [:]

	/// Whether it is known on, noting that a read relies on it now.
	mutating func use(_ key: Generation, at now: ContinuousClock.Instant) -> Bool {
		guard on.contains(key) else { return false }
		owned[key]?.used = now
		return true
	}

	mutating func foundOn(_ key: Generation) { on.insert(key) }

	mutating func turnedOn(_ key: Generation, via: WebAccessibilityVia, at now: ContinuousClock.Instant) {
		on.insert(key)
		owned[key] = (via, now)
	}

	/// Forgets a launch this host turned it on for, returning the attribute to set back; nil for any other.
	mutating func release(_ key: Generation) -> WebAccessibilityVia? {
		guard let entry = owned.removeValue(forKey: key) else { return nil }
		on.remove(key)
		return entry.via
	}

	/// Forgets launches that ended, and returns those this host turned it on for that no read used for `idle`.
	mutating func idle(_ idle: Duration, at now: ContinuousClock.Instant, running: (Generation) -> Bool) -> [Generation] {
		for key in on where !running(key) {
			on.remove(key)
			owned.removeValue(forKey: key)
		}
		return owned.filter { now - $0.value.used >= idle }.map(\.key).sorted { $0.pid < $1.pid }
	}
}

nonisolated(unsafe) private var ledger = WebAccessibilityLedger()
private let enabledLock = NSLock()

/// Empty WKWebView groups a read already waited on, by pid and element hash.
nonisolated(unsafe) private var awaitedGroups: Set<String> = []
private let awaitedLock = NSLock()

extension Mac {
	/// Turns it on for the app's current generation. AXEnhancedUserInterface can change how other apps animate and
	/// place windows, so it is tried only when `chromium` allows it and only after AXManualAccessibility was rejected.
	public static func enableWebAccessibility(pid: pid_t, chromium: Bool) -> (change: WebAccessibilityChange, via: WebAccessibilityVia?) {
		guard let start = generation(pid) else { return (.unknown, nil) }
		let key = Generation(pid: pid, start: start)
		enabledLock.lock()
		defer { enabledLock.unlock() }
		if ledger.use(key, at: .now) { return (.already_on, nil) }
		let application = AXUIElementCreateApplication(pid)
		// A busy renderer must not hold the read for the default six seconds.
		AXUIElementSetMessagingTimeout(application, 1)
		func isOn(_ attribute: String) -> Bool { (AX.value(application, attribute) as? Bool) == true }
		if isOn("AXManualAccessibility") || isOn("AXEnhancedUserInterface") {
			ledger.foundOn(key)
			return (.already_on, nil)
		}
		switch AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) {
		case .success:
			ledger.turnedOn(key, via: .manual, at: .now)
			return (.enabled, .manual)
		case .attributeUnsupported, .notImplemented, .illegalArgument, .actionUnsupported:
			guard chromium else { return (.unsupported, nil) }
			// Chrome reports an error for this set even when it applies it, so only the readback counts.
			_ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
			guard isOn("AXEnhancedUserInterface") else { return (.unsupported, nil) }
			ledger.turnedOn(key, via: .enhanced_ui, at: .now)
			return (.enabled, .enhanced_ui)
		default:
			return (.unknown, nil)
		}
	}

	/// Whether a read found a WKWebView whose tree WebKit hasn't built yet (#5): WebKit builds it in the web content
	/// process only once an assistive client asks, so the first read of a new web view finds only a group, with no
	/// web area, where the page is, and the web area appears under it a moment later. Only an app with a WebKit
	/// content process of its own counts, and each group counts once, so a group that never fills costs one wait.
	public static func awaitsWebKitTree(pid: pid_t, _ elements: [Element]) -> Bool {
		guard !elements.contains(where: { $0.attributes["role"] == "AXWebArea" }) else { return false }
		let waiting = elements.filter { element in
			guard element.attributes["role"] == "AXGroup", element.frame.width >= 100, element.frame.height >= 100 else { return false }
			return awaitsWebArea(element.reference)
		}
		guard !waiting.isEmpty, let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
		      NSWorkspace.shared.runningApplications.contains(where: {
		      	$0.bundleIdentifier == "com.apple.WebKit.WebContent" && $0.localizedName?.hasPrefix(name + " ") == true
		      })
		else { return false }
		let keys = waiting.map { "\(pid):\(CFHash($0.reference))" }
		return awaitedLock.withLock {
			let fresh = keys.filter { !awaitedGroups.contains($0) }
			awaitedGroups.formUnion(fresh)
			if awaitedGroups.count > 512 { awaitedGroups = Set(fresh) }
			return !fresh.isEmpty
		}
	}

	/// Whether a group looks like a web view the read reached before WebKit built its tree: within three levels it
	/// holds a web area the read didn't include, or at most a few elements, such as an empty scroll area.
	static func awaitsWebArea(_ group: AXUIElement) -> Bool {
		var level = [group], seen = 0
		for _ in 0..<3 {
			var next: [AXUIElement] = []
			for element in level {
				AXUIElementSetMessagingTimeout(element, 0.2)
				for child in (AX.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
					if AX.string(child, kAXRoleAttribute) == "AXWebArea" { return true }
					seen += 1
					if seen > 3 { return false }
					next.append(child)
				}
			}
			level = next
		}
		return true
	}

	/// Turns it back off for the app's current generation when this host turned it on, setting back the attribute
	/// it set, so the app stops maintaining a tree for every page (#231). Returns the attribute, or nil when this
	/// host didn't turn it on for this launch, which leaves the app as it is.
	public static func restoreWebAccessibility(pid: pid_t) -> WebAccessibilityVia? {
		guard let start = generation(pid) else { return nil }
		enabledLock.lock()
		defer { enabledLock.unlock() }
		return restoreOwned(Generation(pid: pid, start: start))
	}

	/// Turns it back off for each app this host turned it on for that no read has relied on for `idle`, and
	/// forgets apps that quit. Returns the apps it turned off.
	public static func restoreIdleWebAccessibility(_ idle: Duration) -> [pid_t] {
		enabledLock.lock()
		defer { enabledLock.unlock() }
		return ledger.idle(idle, at: .now) { generation($0.pid) == $0.start }.compactMap { restoreOwned($0) != nil ? $0.pid : nil }
	}

	/// Whether this host turned it on for some running app, so an idle check has something to do.
	public static var ownsWebAccessibility: Bool {
		enabledLock.lock()
		defer { enabledLock.unlock() }
		return !ledger.owned.isEmpty
	}

	/// Call with `enabledLock` held.
	private static func restoreOwned(_ key: Generation) -> WebAccessibilityVia? {
		guard let via = ledger.release(key) else { return nil }
		let application = AXUIElementCreateApplication(key.pid)
		AXUIElementSetMessagingTimeout(application, 1)
		let attribute = via == .manual ? "AXManualAccessibility" : "AXEnhancedUserInterface"
		// Chrome reports an error for this set even when it applies it, as for turning it on.
		_ = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanFalse)
		return via
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

