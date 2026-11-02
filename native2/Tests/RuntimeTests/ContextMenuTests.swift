@testable import DesktopHost
@testable import DesktopMac
import DesktopProtocol
import Testing

/// A right click's context menu closes before a later call can press it in a background app, so the click lists it
/// or chooses an item by literal path in the same call (#227); a plain click can be sent in the foreground (#225).
struct ContextMenuTests {
	final class Item: Sendable {
		let title: String
		let enabled: Bool
		let submenu: [Item]?
		init(_ title: String, enabled: Bool = true, submenu: [Item]? = nil) {
			self.title = title
			self.enabled = enabled
			self.submenu = submenu
		}
	}

	static let menu = Item("", submenu: [
		Item("Rename"), Item("Delete", enabled: false), Item("Rename…"), Item("Dup"), Item("Dup"),
		Item("More", submenu: [Item("Archive")]),
	])

	static func resolve(_ path: [String]) -> Result<Item, Refusal> {
		Mac.resolveMenuPath(menu, path: path, items: { $0.submenu ?? [] }, title: { $0.title }, submenu: { item in item.submenu.map { _ in item } }, enabled: { $0.enabled })
	}

	static func message(_ result: Result<Item, Refusal>) -> String {
		if case let .failure(refusal) = result { return refusal.message }
		return ""
	}

	@Test
	func `a literal path finds the leaf, through a submenu`() throws {
		#expect(try Self.resolve(["Rename"]).get().title == "Rename")
		#expect(try Self.resolve(["More", "Archive"]).get().title == "Archive")
	}

	@Test
	func `missing, ambiguous, disabled and submenu items are refused with what was found`() {
		#expect(Self.message(Self.resolve(["Copy"])).contains("Titles in the context menu: \"Rename\", \"Delete\""))
		#expect(Self.message(Self.resolve(["Dup"])).contains("ambiguous: 2 items"))
		#expect(Self.message(Self.resolve(["Delete"])).contains("disabled"))
		#expect(Self.message(Self.resolve(["More"])).contains("opens a submenu"))
		#expect(Self.message(Self.resolve(["Rename", "x"])).contains("has no submenu"))
	}

	@Test
	func `items list paths, flagging only disabled items and submenus`() {
		let json = Tools.contextMenuJSON([
			ContextMenuRow(path: ["Rename"], enabled: true, submenu: false),
			ContextMenuRow(path: ["Delete"], enabled: false, submenu: false),
			ContextMenuRow(path: ["More"], enabled: true, submenu: true),
		])
		#expect(json.text == #"[{"path":["Rename"]},{"path":["Delete"],"enabled":false},{"path":["More"],"submenu":true}]"#)
	}

	static func refusal(_ arguments: String) async -> String? {
		do {
			_ = try await Tools.click(JSON(parsing: arguments))
			return nil
		} catch let error as ToolError {
			return error.message
		} catch {
			return String(describing: error)
		}
	}

	@Test
	func `foreground takes only left clicks, and menu_path only right clicks`() async {
		#expect(await Self.refusal(#"{"snapshot":"s","point":{"x":0.5,"y":0.5},"kind":"right","foreground":true}"#)?.contains("foreground applies to single") == true)
		#expect(await Self.refusal(#"{"snapshot":"s","point":{"x":0.5,"y":0.5},"menu_path":["Rename"]}"#)?.contains("set kind right") == true)
		#expect(await Self.refusal(#"{"snapshot":"s","point":{"x":0.5,"y":0.5},"kind":"right","menu_path":[]}"#)?.contains("Menu path requires") == true)
		#expect(await Self.refusal(#"{"snapshot":"s","point":{"x":0.5,"y":0.5},"foreground":"yes"}"#)?.contains("foreground to true or false") == true)
	}
}
