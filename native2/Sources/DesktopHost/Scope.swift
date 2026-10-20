import CoreGraphics
import DesktopMac
import DesktopProtocol
import Foundation

// Ported from the native client's read.swift: a scope names an element of an earlier snapshot, found again by
// what identifies it in a fresh traversal of the same window.

/// What identifies a scope element across two traversals of an unchanged window.
private struct ScopeKey: Hashable {
	let role: String?
	let depth: Int
	let frame: [Double]
	let label: String?
	let title: String?
	let identifier: String?

	init(_ element: Element) {
		role = element.attributes["role"]
		depth = element.attributes["depth"].flatMap(Int.init) ?? 0
		frame = [element.frame.minX, element.frame.minY, element.frame.width, element.frame.height].map(Double.init)
		label = element.label
		title = element.attributes["title"]
		identifier = element.attributes["identifier"]
	}
}

struct ScopeSource: Sendable {
	fileprivate let key: ScopeKey
	/// Earlier elements with the same key, and all elements with it, in the source traversal.
	fileprivate let ordinal: Int
	fileprivate let matches: Int
	let generation: UInt64
}

private func scopeError(_ message: String) -> ToolError { ToolError("DESKTOP_ERROR: \(message).") }

extension Tools {
	/// Reads the scope element from its own snapshot, which must observe the same process and window.
	static func scopeSource(_ scope: ScopeRequest, pid: pid_t, windowID: Int) async throws -> ScopeSource {
		guard scope.snapshot.range(of: "^ps1_[0-9a-f]{32}$", options: .regularExpression) != nil else {
			throw ToolError("invalidRequest: Invalid producer-bound snapshot reference.")
		}
		guard let snapshot = await Snapshots.shared.get(scope.snapshot) else {
			throw scopeError("The scope snapshot no longer belongs to the running desktop. Inspect the window again.")
		}
		guard snapshot.windowID == windowID, snapshot.pid == pid else {
			throw scopeError("The scope snapshot observed a different window. Inspect this window and choose an element from it.")
		}
		let elements = preorder(Array(snapshot.elements.values))
		guard let position = elements.firstIndex(where: { $0.id == scope.element }) else {
			throw scopeError("The scope element ID is not in that snapshot's window elements. Choose one from its ui_elements.")
		}
		let key = ScopeKey(elements[position])
		let same = elements.indices.filter { ScopeKey(elements[$0]) == key }
		return ScopeSource(key: key, ordinal: same.firstIndex(of: position)!, matches: same.count, generation: snapshot.generation)
	}

	/// Finds the scope element in a fresh traversal, refusing when it moved, changed or became ambiguous.
	static func locateScope(_ source: ScopeSource, in elements: [Element], generation: UInt64) throws -> Int {
		guard source.generation == generation else {
			throw scopeError("The application restarted since the scope snapshot. Inspect the window again.")
		}
		let same = elements.indices.filter { ScopeKey(elements[$0]) == source.key }
		if same.count == 1 { return same[0] }
		if same.count == source.matches, same.count > source.ordinal { return same[source.ordinal] }
		throw scopeError(same.isEmpty
			? "The scope element was not found unchanged in a fresh read; it may have moved, changed or been removed. Inspect the window again and choose the element from that result."
			: "The scope element matches several identical elements in a fresh read. Choose an enclosing element as the scope.")
	}

	/// Window elements in traversal pre-order, which their IDs number.
	static func preorder(_ elements: [Element]) -> [Element] {
		elements.filter { $0.id.hasPrefix("elem_") }.sorted { Int($0.id.dropFirst(5)) ?? 0 < Int($1.id.dropFirst(5)) ?? 0 }
	}

	/// The element followed by its descendants, which continue until an element at its depth or above.
	static func subtree(_ elements: [Element], at position: Int) -> [Element] {
		let depth = { (element: Element) in element.attributes["depth"].flatMap(Int.init) ?? 0 }
		var end = position + 1
		while end < elements.count, depth(elements[end]) > depth(elements[position]) { end += 1 }
		return Array(elements[position..<end])
	}

	/// The size of each web area's subtree: a Chromium web view lists at most one element under it before its
	/// web accessibility is on.
	static func webAreas(_ elements: [Element]) -> [Int] {
		let ordered = preorder(elements)
		return ordered.indices.filter { ordered[$0].attributes["role"] == "AXWebArea" }.map { subtree(ordered, at: $0).count }
	}
}

extension Tools {
	/// Reads a window with its app's web accessibility turned on when `allowed`: before the read for an app that
	/// ships Chromium, or after a read that found a nearly empty web area; then reads again once the tree is built.
	/// Ported from the native client's WebAccessibilityPolicy.
	static func webRead<T>(
		pid: pid_t, allowed: Bool, tree: (T) -> ElementTree, _ read: () async throws -> T
	) async throws -> (T, (change: WebAccessibilityChange, via: WebAccessibilityVia?)?) {
		var web: (change: WebAccessibilityChange, via: WebAccessibilityVia?)?
		if allowed, Mac.shipsChromium(pid) {
			web = Mac.enableWebAccessibility(pid: pid, chromium: true)
			if web?.change == .enabled { try await Task.sleep(for: .milliseconds(500)) }
		}
		let first = try await read()
		guard allowed, !tree(first).truncated else { return (first, web) }
		if web?.change == .enabled {
			// A fresh Chrome turned on with AXEnhancedUserInterface can take over a second to build its tree.
			guard !webAreas(tree(first).elements).contains(where: { $0 > 2 }) else { return (first, web) }
			try await Task.sleep(for: .seconds(1))
			return (try await read(), web)
		}
		guard web == nil, webAreas(tree(first).elements).contains(where: { $0 <= 2 }) else { return (first, web) }
		web = Mac.enableWebAccessibility(pid: pid, chromium: Mac.shipsChromium(pid))
		guard web?.change == .enabled else { return (first, web) }
		try await Task.sleep(for: .milliseconds(500))
		return (try await read(), web)
	}
}

/// A duration in seconds.
func seconds(_ duration: Duration) -> Double {
	Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
