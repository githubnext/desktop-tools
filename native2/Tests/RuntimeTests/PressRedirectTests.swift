@testable import DesktopMac
import Testing

/// WebKit presses an ARIA menu item or button through the first native control inside it, so a point click on a
/// menu row must not AXPress a row that holds a remove button (#195).
struct PressRedirectTests {
	final class Node {
		let role: String
		let children: [Node]
		init(_ role: String, _ children: [Node] = []) {
			self.role = role
			self.children = children
		}
	}

	static func control(in node: Node) -> Node? {
		Mac.nativeControl(in: node, role: { $0.role }, children: { $0.children })
	}

	@Test
	func `a menu row holding a remove button is found to redirect, depth first like WebCore`() {
		let remove = Node("AXButton")
		let row = Node("AXMenuItem", [Node("AXStaticText"), Node("AXGroup", [remove]), Node("AXCheckBox")])
		#expect(Mac.webPressRedirects(role: "AXMenuItem"))
		#expect(Self.control(in: row) === remove)
	}

	@Test
	func `a row with only text, or a link, has no control to redirect to`() {
		#expect(Self.control(in: Node("AXMenuItem", [Node("AXStaticText"), Node("AXGroup", [Node("AXImage")])])) == nil)
		#expect(Self.control(in: Node("AXMenuItem", [Node("AXLink", [Node("AXStaticText")])])) == nil)
	}

	@Test
	func `text fields and links are pressed directly, whatever they hold`() {
		for role in ["AXTextField", "AXLink", "AXStaticText", "AXCell"] {
			#expect(!Mac.webPressRedirects(role: role))
		}
	}

	@Test
	func `the search stops at six levels`() {
		var node = Node("AXButton")
		for _ in 0..<6 { node = Node("AXGroup", [node]) }
		#expect(Self.control(in: Node("AXMenuItem", [node])) == nil)
		#expect(Self.control(in: Node("AXMenuItem", node.children)) != nil)
	}
}
