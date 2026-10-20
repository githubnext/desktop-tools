@testable import DesktopMac
import CoreGraphics
import Foundation
import Testing

/// The WindowServer status item inventory, used where MenuBarAgent doesn't draw the menu bar.
struct MenuBarWindowTests {
	// No process has this pid, so no running app is found for it.
	static let pid: Int32 = 999_999
	static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

	static func info(layer: Int, owner: String = "Weather", title: String? = nil, x: Double = 100) -> [String: Any] {
		var info: [String: Any] = [
			kCGWindowLayer as String: NSNumber(value: layer), kCGWindowOwnerPID as String: NSNumber(value: pid),
			kCGWindowOwnerName as String: owner,
			kCGWindowBounds as String: CGRect(x: x, y: 0, width: 30, height: 24).dictionaryRepresentation as NSDictionary,
		]
		if let title { info[kCGWindowName as String] = title }
		return info
	}

	@Test
	func `only windows on the main menu and status layers are items, and never the bar itself`() {
		#expect(windowItem(Self.info(layer: 0), id: 1, source: "cgwindow", displays: [Self.display]) == nil)
		#expect(windowItem(Self.info(layer: 26), id: 1, source: "cgwindow", displays: [Self.display]) == nil)
		#expect(windowItem(Self.info(layer: 24, owner: "Window Server", title: "Menubar"), id: 1, source: "cgs", displays: [Self.display]) == nil)
		let item = windowItem(Self.info(layer: 25, title: "Forecast"), id: 7, source: "cgs", displays: [Self.display])
		#expect(item?.windowID == 7 && item?.windowLayer == 25 && item?.source == "cgs" && item?.element == nil)
		#expect(item?.title == "Forecast" && item?.identifier == "Forecast" && item?.isVisible == true)
	}

	@Test
	func `an untitled window is named for its owner, and one off the displays is not visible`() {
		let item = windowItem(Self.info(layer: 25, x: 4000), id: 8, source: "cgwindow", displays: [Self.display])
		#expect(item?.label == "Weather" && item?.title == "Weather" && item?.identifier == nil && item?.isVisible == false)
	}

	@Test
	func `system owners' placeholders take their product's name, and Control Center's names are spaced`() {
		#expect(windowItemName(rawTitle: "Item-0", ownerName: "Control Centre", bundleID: "com.apple.controlcenter") == "Control Center")
		#expect(windowItemName(rawTitle: "Menu Extras", ownerName: "SystemUIServer", bundleID: "com.apple.systemuiserver") == "System Menu Extras")
		#expect(windowItemName(rawTitle: "FocusModes", ownerName: "Control Centre", bundleID: "com.apple.controlcenter") == "Focus Modes")
		#expect(windowItemName(rawTitle: "Item-0", ownerName: "Weather", bundleID: "com.example.weather") == "Weather")
		#expect(windowItemName(rawTitle: "Forecast", ownerName: "Weather", bundleID: "com.example.weather") == "Forecast")
	}

	@Test
	func `items run top to bottom, then left to right, then by window`() {
		func item(_ id: Int, x: Double, y: Double) -> Extra {
			Extra(pid: Self.pid, label: nil, identifier: nil, title: "", ownerName: nil, bundleID: nil, frame: CGRect(x: x, y: y, width: 20, height: 20),
			      isVisible: true, actions: [], element: nil, windowID: id)
		}
		let ordered = windowItemsInOrder([item(4, x: 50, y: 30), item(3, x: 200, y: 0), item(2, x: 50, y: 0), item(1, x: 50, y: 0)])
		#expect(ordered.map(\.windowID) == [1, 2, 3, 4])
	}
}
