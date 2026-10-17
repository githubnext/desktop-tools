import AppKit
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

/// What a read did about a Chromium or Electron app's web accessibility, which those apps build only when an
/// assistive client asks; until then a web view lists few or no elements. The host sets it at most once per launch.
enum WebAccessibility: String, Encodable {
	/// This read turned it on.
	case enabled
	/// It was already on, from an earlier read or another assistive app such as VoiceOver.
	case already_on
	/// The app doesn't accept it, and nothing changed.
	case unsupported
	/// The request failed or wasn't confirmed; the read went ahead with the tree as it was.
	case unknown
}

/// Whether reads may turn on web accessibility: the caller allows it and the host offers it.
struct WebAccessibilityPolicy {
	let allowed: Bool

	/// How long a page gets to build its tree after it is turned on, before the window is read.
	static let settle: Duration = .milliseconds(500)

	init(allowed: Bool, handshake: PeekabooBridgeHandshakeResponse) {
		self.allowed = allowed && handshake.enabledOperations?.contains(.enableWebAccessibility) == true
	}

	/// Turns it on before the first read of an app that ships Chromium, waiting for the tree when it was off.
	func beforeRead(_ client: PeekabooBridgeClient, pid: Int32) async -> WebAccessibility? {
		guard allowed, shipsChromium(pid) else { return nil }
		let state = await enable(client, pid: pid)
		if state == .enabled { try? await Task.sleep(for: Self.settle) }
		return state
	}

	/// After a read that found a nearly empty web area in an app not handled before the read, turns it on.
	/// Returns the new state, and whether the window should be read again.
	func afterRead(
		_ client: PeekabooBridgeClient, pid: Int32, elements: [DetectedElement], truncated: Bool,
		before: WebAccessibility?
	) async -> (state: WebAccessibility?, readAgain: Bool) {
		guard allowed, before == nil, !truncated, hasSparseWebArea(elements) else { return (before, false) }
		let state = await enable(client, pid: pid)
		guard state == .enabled else { return (state, false) }
		try? await Task.sleep(for: Self.settle)
		return (state, true)
	}

	private func enable(_ client: PeekabooBridgeClient, pid: Int32) async -> WebAccessibility {
		guard let start = SystemIdentityResolver.processStartIdentity(pid) else { return .unknown }
		do {
			let result = try await client.enableWebAccessibilityWithOutcome(
				ApplicationProcessIdentity(processIdentifier: pid, processStartIdentity: start)
			)
			return result.payload ? .enabled : .already_on
		} catch let envelope as PeekabooBridgeErrorEnvelope where envelope.code == .operationNotSupported {
			return .unsupported
		} catch {
			return .unknown
		}
	}
}

/// Whether the app's bundle ships Chromium: an Electron or Chromium Embedded framework, or a framework with
/// Chromium's crash handler among its helpers, as Chrome, Edge and other Chromium-based apps have.
private func shipsChromium(_ pid: Int32) -> Bool {
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

/// Whether a web area has at most one element under it, as a Chromium web view shows before its tree is on.
private func hasSparseWebArea(_ elements: [DetectedElement]) -> Bool {
	guard let ordered = try? preorder(elements) else { return false }
	return ordered.indices.contains { position in
		ordered[position].element.attributes["role"] == "AXWebArea" && subtree(ordered, at: position).count <= 2
	}
}

/// The last client argument of inspect or read that leaves the app's web accessibility as it is.
let keepWebAccessibility = "keep-web-accessibility"
