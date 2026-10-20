import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct AXWindowIDResolverTests {
    private struct Node {
        var processIdentifier: pid_t = 7
        var role: String?
        var windowID: CGWindowID?
        var window: AXUIElement?
        var parent: AXUIElement?
    }

    private let field = AXUIElementCreateApplication(-101)
    private let group = AXUIElementCreateApplication(-102)
    private let sheet = AXUIElementCreateApplication(-103)
    private let document = AXUIElementCreateApplication(-104)
    private let panelService = AXUIElementCreateApplication(-105)

    private func tree(_ nodes: [(AXUIElement, Node)]) -> AXWindowIDResolver.Tree {
        let node = { (element: AXUIElement) in nodes.first { CFEqual($0.0, element) }?.1 }
        return AXWindowIDResolver.Tree(
            windowID: { node($0)?.windowID },
            attribute: { name, element in
                switch name {
                case kAXRoleAttribute: node(element)?.role as CFTypeRef?
                case kAXWindowAttribute: node(element)?.window
                case kAXParentAttribute: node(element)?.parent
                default: nil
                }
            },
            processIdentifier: { node($0)?.processIdentifier })
    }

    @Test
    func `a same-process AXWindow link names the owning window`() {
        let tree = self.tree([
            (self.field, Node(role: "AXTextField", windowID: 9, window: self.document, parent: self.group)),
            (self.document, Node(role: "AXWindow", windowID: 42)),
        ])
        #expect(AXWindowIDResolver.owner(of: self.field, tree: tree) == .init(windowID: 42))
    }

    @Test
    func `sheet content belongs to the window the sheet is attached to`() {
        let tree = self.tree([
            (self.field, Node(role: "AXTextField", windowID: 43, window: self.sheet, parent: self.group)),
            (self.group, Node(role: "AXGroup", parent: self.sheet)),
            (self.sheet, Node(role: "AXSheet", windowID: 43, parent: self.document)),
            (self.document, Node(role: "AXWindow", windowID: 42)),
        ])
        #expect(AXWindowIDResolver.owner(of: self.field, tree: tree) == .init(windowID: 42, sheetWindowID: 43))
        #expect(AXWindowIDResolver.owningWindowID(of: self.field, tree: tree) == 42)
    }

    @Test
    func `nested sheet content keeps the innermost sheet`() {
        let inner = AXUIElementCreateApplication(-106)
        let tree = self.tree([
            (self.field, Node(role: "AXTextField", window: inner, parent: inner)),
            (inner, Node(role: "AXSheet", windowID: 44, parent: self.sheet)),
            (self.sheet, Node(role: "AXSheet", windowID: 43, parent: self.document)),
            (self.document, Node(role: "AXWindow", windowID: 42)),
        ])
        #expect(AXWindowIDResolver.owner(of: self.field, tree: tree) == .init(windowID: 42, sheetWindowID: 44))
    }

    @Test(arguments: [true, false])
    func `remote save panel content belongs to the document window`(linksServiceWindow: Bool) {
        let tree = self.tree([
            (self.field, Node(
                role: "AXTextField",
                windowID: 173,
                window: linksServiceWindow ? self.panelService : nil,
                parent: self.group)),
            (self.panelService, Node(processIdentifier: 8, role: "AXWindow", windowID: 173)),
            (self.group, Node(role: "AXSplitGroup", parent: self.sheet)),
            (self.sheet, Node(role: "AXSheet", windowID: 172, parent: self.document)),
            (self.document, Node(role: "AXWindow", windowID: 167)),
        ])
        #expect(AXWindowIDResolver.owner(of: self.field, tree: tree) == .init(windowID: 167, sheetWindowID: 172))
    }

    @Test
    func `an element without a window ancestor keeps its direct identity`() {
        let tree = self.tree([
            (self.field, Node(role: "AXMenuItem", windowID: 44, parent: self.group)),
            (self.group, Node(role: "AXMenu")),
        ])
        #expect(AXWindowIDResolver.owningWindowID(of: self.field, tree: tree) == 44)
    }

    @Test(arguments: [CGWindowID?.none, .some(0)])
    func `unresolved windows never fabricate an identity`(windowID: CGWindowID?) {
        let tree = self.tree([
            (self.field, Node(role: "AXTextField", windowID: windowID, window: self.document, parent: self.document)),
            (self.document, Node(role: "AXWindow", windowID: windowID)),
        ])
        #expect(AXWindowIDResolver.owningWindowID(of: self.field, tree: tree) == nil)
    }
}
