import CoreGraphics
import Foundation

/// One observed Accessibility element in traversal pre-order, with its depth below the window.
struct TextNode {
	let role: String
	let depth: Int
	let label: String?
	let value: String?
	let bounds: CGRect
}

/// Roles whose own text is their content.
private let contentRoles: Set<String> = ["AXStaticText", "AXText"]
/// Editable or read-only text controls; their value is their content.
private let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
/// Controls whose label names them; it is read only when no descendant supplies text.
private let labelRoles: Set<String> = [
	"AXButton", "AXLink", "AXHeading", "AXCell", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
	"AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXMenuBarItem", "AXDateField", "AXTimeField",
]

struct ReadableText {
	let text: String
	let truncated: Bool
	/// Text pieces left out after the byte limit.
	let omitted: Int
	let pieces: Int
}

/// The readable text of `nodes`, a complete pre-order subtree list, in reading order within `limit` UTF-8 bytes.
func readableText(_ nodes: [TextNode], limit: Int) -> ReadableText {
	var pieces: [(text: String, bounds: CGRect)] = []
	var index = 0
	while index < nodes.count { collect(nodes, &index, into: &pieces) }
	var text = ""
	var bytes = 0
	var previous: (text: String, bounds: CGRect)?
	for (position, piece) in pieces.enumerated() {
		// Some apps expose the same text twice at one place, as a title and as its static text.
		if let previous, previous.text == piece.text, previous.bounds == piece.bounds { continue }
		let separator = previous.map { separatorBetween($0, piece) } ?? ""
		let addition = separator + piece.text
		let size = addition.utf8.count
		if bytes + size > limit {
			// Keep whole characters within the limit.
			var room = limit - bytes
			var kept = ""
			for character in addition {
				let count = String(character).utf8.count
				guard count <= room else { break }
				kept.append(character)
				room -= count
			}
			text += kept
			return ReadableText(text: text, truncated: true, omitted: pieces.count - position, pieces: pieces.count)
		}
		text += addition
		bytes += size
		previous = piece
	}
	return ReadableText(text: text, truncated: false, omitted: 0, pieces: pieces.count)
}

private func collect(_ nodes: [TextNode], _ index: inout Int, into pieces: inout [(text: String, bounds: CGRect)]) {
	let node = nodes[index]
	index += 1
	var inner: [(text: String, bounds: CGRect)] = []
	while index < nodes.count, nodes[index].depth > node.depth { collect(nodes, &index, into: &inner) }
	let own = { (value: String?) -> (text: String, bounds: CGRect)? in
		guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return (value, node.bounds)
	}
	if contentRoles.contains(node.role) {
		if let text = own(node.value) ?? own(node.label) { pieces.append(text) }
		pieces += inner
	} else if fieldRoles.contains(node.role) {
		// A web text area also lists its value as static text children.
		if let text = own(node.value) { pieces.append(text) } else { pieces += inner }
	} else if labelRoles.contains(node.role) {
		if inner.isEmpty, let text = own(node.role == "AXPopUpButton" ? node.value ?? node.label : node.label) {
			pieces.append(text)
		} else {
			pieces += inner
		}
	} else {
		pieces += inner
	}
}

/// Text on the same visual line continues it; anything else starts a new line.
private func separatorBetween(_ previous: (text: String, bounds: CGRect), _ next: (text: String, bounds: CGRect))
	-> String
{
	let a = previous.bounds, b = next.bounds
	// The next piece starts inside the previous piece's vertical extent, as an inline link or wrapped text does.
	let sameLine = b.minY >= a.minY - 2 && b.minY < a.maxY - min(4, b.height / 2)
	guard sameLine else { return "\n" }
	if b.minX >= a.maxX - 1, b.minX - a.maxX > 24 { return "\t" }
	if previous.text.last?.isWhitespace == true || next.text.first?.isWhitespace == true { return "" }
	if let first = next.text.first, ".,;:!?)]}%".contains(first) { return "" }
	if let last = previous.text.last, "([{/".contains(last) { return "" }
	return " "
}
