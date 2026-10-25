@testable import DesktopMac
import CoreGraphics
import Testing

/// Chrome's vertical tab strip lays empty groups over its tabs; a point click must find the tab beneath (#202).
struct OverlayClickTests {
	struct Node {
		let name: String
		var role = "AXGroup"
		var actions: [String] = []
		var area: CGFloat = 100
		var leaf = true
	}

	static func beneath(_ hit: Node, under: [Node], ancestors: Int = 1) -> [String] {
		Mac.beneath(
			hit, ancestors: (0..<ancestors).map { Node(name: "ancestor\($0)", leaf: false) }, role: \.role, isLeaf: \.leaf,
			actions: \.actions, atPoint: { _ in [hit] + under }, area: \.area, same: { $0.name == $1.name }
		).map(\.name)
	}

	@Test
	func `an empty overlay gives way to the pressable elements beneath, smallest first`() {
		let tab = Node(name: "tab", role: "AXRadioButton", actions: ["AXPress"], area: 6000)
		let close = Node(name: "close", role: "AXButton", actions: ["AXPress"], area: 800)
		let row = Node(name: "row", area: 9000, leaf: false)
		#expect(Self.beneath(Node(name: "overlay", area: 200_000), under: [row, tab, close]) == ["close", "tab"])
	}

	@Test
	func `a hit with children or actions is not an overlay`() {
		let tab = Node(name: "tab", role: "AXRadioButton", actions: ["AXPress"])
		#expect(Self.beneath(Node(name: "group", leaf: false), under: [tab]).isEmpty)
		#expect(Self.beneath(Node(name: "group", actions: ["AXScrollToVisible"]), under: [tab]).isEmpty)
		#expect(Self.beneath(Node(name: "text", role: "AXStaticText"), under: [tab]).isEmpty)
		#expect(Self.beneath(Node(name: "overlay"), under: [tab], ancestors: 0).isEmpty)
	}
}
