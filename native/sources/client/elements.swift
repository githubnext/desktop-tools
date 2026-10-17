import Foundation
import PeekabooAutomationKit
import PeekabooBridge

/// One wait poll: matching elements, or the text, of one exact window or one element's subtree.
private struct ElementsRequest: Decodable {
	let pid: Int32
	let window: UInt32
	let scope: Scope?
	let match: Match?
	let text: Bool?
	/// False leaves a Chromium or Electron app's web accessibility as it is.
	let web_accessibility: Bool?

	struct Scope: Decodable {
		let snapshot: String
		let element: String
	}

	/// The role, plus any of an exact title, value and identifier.
	struct Match: Decodable {
		let role: String
		let title: String?
		let value: String?
		let identifier: String?
	}
}

private struct FoundElement: Encodable {
	let role: String
	let label: String?
	let value: String?
	let title: String?
	let identifier: String?
	let depth: Int
	let bounds: Bounds
	let is_enabled: Bool
}

private struct Found: Encodable {
	let application_name: String?
	let window_title: String?
	let matches: [FoundElement]?
	let match_count: Int?
	let text: String?
	let element_count: Int
	let traversed_element_count: Int
	let truncated: Bool
	let truncation: [String]
	let web_accessibility: WebAccessibility?
}

private struct FoundReply: Encodable {
	let success = true
	let data: Found
	let target_receipt: Receipt
}

private let elementsMatchLimit = 20

/// Whether an element's AX or listed role, label or title, value and identifier equal the request's.
private func matches(_ element: DetectedElement, _ match: ElementsRequest.Match) -> Bool {
	let attributes = element.attributes
	guard attributes["role"] == match.role || element.type.rawValue == match.role else { return false }
	if let title = match.title, element.label != title, attributes["title"] != title { return false }
	if let value = match.value, readableValue(element) != value { return false }
	if let identifier = match.identifier, attributes["identifier"] != identifier { return false }
	return true
}

/// The value an agent may see; secure text field values are never read.
private func readableValue(_ element: DetectedElement) -> String? {
	isSecure(element) ? nil : element.value
}

/// Whether an element is a secure text field, such as a password field. The host reports one by its subrole, since
/// its role is AXTextField; some apps report the subrole as the role.
func isSecure(_ element: DetectedElement) -> Bool {
	element.attributes["role"] == "AXSecureTextField" || element.attributes["subrole"] == "AXSecureTextField"
}

/// Reads one exact window through Accessibility alone, with the large read budget: no screenshot, no
/// stored snapshot and no input. Each call is one observation, so a wait holds nothing between polls.
func nativeElements(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		guard data.count + chunk.count <= 65_536 else { throw ReadError("The elements request exceeds 64 KiB.") }
		data.append(chunk)
	}
	let request = try JSONDecoder().decode(ElementsRequest.self, from: data)
	let pid = request.pid, window = request.window
	guard pid > 0, window > 0, (request.match == nil) != (request.text != true) else {
		throw ReadError("Read either matching elements or text of one window.")
	}
	if let match = request.match {
		guard !match.role.isEmpty, match.title != nil || match.value != nil || match.identifier != nil else {
			throw ReadError("Match an element by its role and at least one of title, value or identifier.")
		}
	}
	var source: ScopeSource?
	if let scope = request.scope {
		source = try await scopeSource(client, ScopeRequest(snapshot: scope.snapshot, element: scope.element), pid: pid, window: window)
	}
	func observe() async throws -> ElementDetectionResult {
		try await client.inspectAccessibilityTree(windowContext: WindowContext(
			applicationProcessId: pid,
			windowID: Int(window),
			shouldFocusWebContent: false,
			includeMenuBarElements: false,
			traversalBudget: wideTraversal,
			requiresFreshAccessibilityTree: true
		))
	}
	let web = WebAccessibilityPolicy(allowed: request.web_accessibility != false, handshake: handshake)
	let before = await web.beforeRead(client, pid: pid)
	var detection = try await observe()
	let after = await web.afterRead(
		client, pid: pid, elements: detection.elements.all,
		truncated: !traversalTruncation(detection.metadata.truncationInfo).isEmpty, before: before
	)
	if after.readAgain { detection = try await observe() }
	guard let context = detection.metadata.windowContext,
		context.applicationProcessId == pid, context.windowID == Int(window),
		let generation = context.applicationProcessStartIdentity
	else { throw ReadError("The Accessibility read did not confirm the requested process and window. Refresh the window list and try again.") }
	let elements = try preorder(detection.elements.all)
	var selected = elements[...]
	if let source {
		selected = subtree(elements, at: try locateScope(source, in: elements, processStartIdentity: generation))
	}
	var found: [OrderedElement]?
	if let match = request.match { found = selected.filter { matches($0.element, match) } }
	var truncation = traversalTruncation(detection.metadata.truncationInfo)
	var text: String?
	if request.text == true {
		let reading = readableText(textNodes(selected), limit: readTextLimit)
		if reading.truncated { truncation.insert("text_limit", at: 0) }
		text = reading.text
	}
	let reply = Found(
		application_name: context.applicationName,
		window_title: context.windowTitle,
		matches: found?.prefix(elementsMatchLimit).map {
			FoundElement(
				role: $0.element.attributes["role"] ?? $0.element.type.rawValue,
				label: $0.element.label,
				value: readableValue($0.element),
				title: $0.element.attributes["title"],
				identifier: $0.element.attributes["identifier"],
				depth: $0.depth,
				bounds: Bounds($0.element.bounds),
				is_enabled: $0.element.isEnabled
			)
		},
		match_count: found?.count,
		text: text,
		element_count: selected.count,
		traversed_element_count: elements.count,
		truncated: !truncation.isEmpty,
		truncation: truncation,
		web_accessibility: after.state
	)
	return try JSONEncoder().encode(FoundReply(data: reply, target_receipt: .init(
		pid: pid,
		window_id: Int(window),
		process_start_identity_decimal: String(generation)
	)))
}
