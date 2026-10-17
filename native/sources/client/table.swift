import Foundation
import PeekabooAutomationKit
import PeekabooBridge

/// One table read: the scope element of an earlier snapshot, read again through Accessibility alone.
private struct TableRequest: Decodable {
	let pid: Int32
	let window: UInt32
	let snapshot: String
	let element: String
}

private struct TableElement: Encodable {
	/// The element's ID in the scope snapshot, when that snapshot stored it unchanged.
	let id: String?
	let role: String
	let depth: Int
	let label: String?
	let value: String?
	let title: String?
	let description: String?
	let role_description: String?
	let bounds: Bounds
	let selected: Bool?
	let disclosure_level: Int?
	let disclosing: Bool?
}

private struct TableScope: Encodable {
	let snapshot: String
	let element: String
	let role: String?
	let label: String?
}

private struct TableElements: Encodable {
	let application_name: String?
	let window_title: String?
	let scope: TableScope
	let elements: [TableElement]
	let traversed_element_count: Int
	let truncated: Bool
	let truncation: [String]
}

private struct TableReply: Encodable {
	let success = true
	let data: TableElements
	let target_receipt: Receipt
}

/// Each text field is cut to this many characters, so a table of long cells still fits one reply.
private let tableFieldLimit = 512
/// The serialized elements stop here, well inside the TypeScript caller's output limit.
private let tableOutputLimit = 1_500_000

private func clipped(_ text: String?) -> (String?, Bool) {
	guard let text, text.count > tableFieldLimit else { return (text, false) }
	return (String(text.prefix(tableFieldLimit)), true)
}

/// Maps each fresh element to its ID in the snapshot when both traversals hold the same elements with its key.
private func snapshotIDs(_ fresh: [OrderedElement], _ stored: [OrderedElement]) -> [Int: String] {
	let storedByKey = Dictionary(grouping: stored, by: ScopeKey.init)
	var ids: [Int: String] = [:]
	for (key, same) in Dictionary(grouping: fresh, by: ScopeKey.init) {
		guard let candidates = storedByKey[key], candidates.count == same.count else { continue }
		for (element, candidate) in zip(same, candidates) { ids[element.order] = candidate.element.id }
	}
	return ids
}

/// Lists the scope element's subtree for a table read, without a screenshot, a new snapshot or any input.
func nativeTable(_ client: PeekabooBridgeClient) async throws -> Data {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		guard data.count + chunk.count <= 4096 else { throw ReadError("The table request exceeds 4 KiB.") }
		data.append(chunk)
	}
	let request = try JSONDecoder().decode(TableRequest.self, from: data)
	let pid = request.pid, window = request.window
	guard pid > 0, window > 0 else { throw ReadError("Read a table of one window by its pid and window ID.") }
	let source = try await scopeSource(
		client, ScopeRequest(snapshot: request.snapshot, element: request.element), pid: pid, window: window
	)
	let detection = try await client.inspectAccessibilityTree(windowContext: WindowContext(
		applicationProcessId: pid,
		windowID: Int(window),
		shouldFocusWebContent: false,
		includeMenuBarElements: false,
		traversalBudget: wideTraversal,
		requiresFreshAccessibilityTree: true
	))
	guard let context = detection.metadata.windowContext,
		context.applicationProcessId == pid, context.windowID == Int(window),
		let generation = context.applicationProcessStartIdentity
	else { throw ReadError("The Accessibility read did not confirm the requested process and window. Refresh the window list and try again.") }
	let elements = try preorder(detection.elements.all)
	let position = try locateScope(source, in: elements, processStartIdentity: generation)
	let selected = subtree(elements, at: position)
	let ids = snapshotIDs(elements, source.snapshotElements)
	var truncation = traversalTruncation(detection.metadata.truncationInfo)
	var listed: [TableElement] = []
	var bytes = 0
	var clippedText = false
	for item in selected {
		let element = item.element
		let attributes = element.attributes
		let role = attributes["role"] ?? element.type.rawValue
		let (label, a) = clipped(element.label)
		let (value, b) = clipped(isSecure(element) ? nil : element.value)
		let (title, c) = clipped(attributes["title"])
		let (description, d) = clipped(attributes["description"])
		clippedText = clippedText || a || b || c || d
		let row = TableElement(
			id: ids[item.order],
			role: role,
			depth: item.depth,
			label: label,
			value: value,
			title: title,
			description: description,
			role_description: attributes["roleDescription"],
			bounds: Bounds(element.bounds),
			selected: element.isSelected,
			disclosure_level: attributes["disclosureLevel"].flatMap(Int.init),
			disclosing: attributes["disclosing"].map { $0 == "true" }
		)
		bytes += try JSONEncoder().encode(row).count + 1
		guard bytes <= tableOutputLimit else {
			truncation.append("output_limit")
			break
		}
		listed.append(row)
	}
	if clippedText { truncation.append("field_text_limit") }
	let root = elements[position].element
	let reply = TableElements(
		application_name: context.applicationName,
		window_title: context.windowTitle,
		scope: TableScope(
			snapshot: request.snapshot, element: request.element, role: root.attributes["role"], label: root.label
		),
		elements: listed,
		traversed_element_count: elements.count,
		truncated: !truncation.isEmpty,
		truncation: truncation
	)
	return try JSONEncoder().encode(TableReply(data: reply, target_receipt: .init(
		pid: pid,
		window_id: Int(window),
		process_start_identity_decimal: String(generation)
	)))
}
