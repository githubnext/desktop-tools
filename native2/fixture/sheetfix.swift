import AppKit
import SwiftUI
// The sheet fixture (#243, #245): an AppKit window whose buttons open a custom sheet with beginSheet and an NSAlert
// sheet, and a second window hosting a SwiftUI view with .alert(isPresented:). Every sheet's buttons close it, and
// the fixture logs each open, close and button to stdout, so a test can tell a click that worked from one that didn't.
// Build it with `swiftc -O native2/fixture/sheetfix.swift -o native2/.build/sheetfix`; the process is "sheetfix".
func log(_ s: String) { print(s); fflush(stdout) }

final class Controller: NSObject {
	let window: NSWindow
	var sheet: NSWindow?

	init(window: NSWindow) { self.window = window }

	@objc func openSheet(_ sender: Any?) {
		let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
		let label = NSTextField(labelWithString: "Delete the selected item?")
		label.frame = NSRect(x: 20, y: 90, width: 280, height: 22)
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet(_:)))
		cancel.frame = NSRect(x: 120, y: 20, width: 90, height: 32)
		cancel.keyEquivalent = "\u{1b}"
		let delete = NSButton(title: "Delete", target: self, action: #selector(closeSheet(_:)))
		delete.frame = NSRect(x: 215, y: 20, width: 90, height: 32)
		delete.keyEquivalent = "\r"
		for view in [label, cancel, delete] { sheet.contentView!.addSubview(view) }
		self.sheet = sheet
		log("sheet open")
		window.beginSheet(sheet) { response in log("sheet closed \(response.rawValue)") }
	}

	@objc func closeSheet(_ sender: NSButton) {
		log("sheet button \(sender.title)")
		guard let sheet else { return }
		window.endSheet(sheet, returnCode: sender.title == "Delete" ? .OK : .cancel)
		self.sheet = nil
	}

	@objc func openAlert(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Remove the file?"
		alert.informativeText = "This can't be undone."
		alert.addButton(withTitle: "Remove")
		alert.addButton(withTitle: "Cancel")
		log("alert open")
		alert.beginSheetModal(for: window) { response in log("alert closed \(response.rawValue)") }
	}
}

struct AlertView: View {
	@State private var showing = false
	@State private var status = "No answer yet"

	var body: some View {
		VStack(spacing: 16) {
			Text(status)
			Button("Show Alert") { log("swiftui alert open"); showing = true }
		}
		.frame(width: 360, height: 220)
		.alert("Delete project?", isPresented: $showing) {
			Button("Delete", role: .destructive) { log("swiftui alert Delete"); status = "Deleted" }
			Button("Cancel", role: .cancel) { log("swiftui alert Cancel"); status = "Cancelled" }
		} message: {
			Text("The project and its files will be removed.")
		}
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: "sheetfix")
appItem.submenu!.addItem(withTitle: "Quit sheetfix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 420, height: 260), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Sheet Fixture"
window.isReleasedWhenClosed = false
let controller = Controller(window: window)
let openSheet = NSButton(title: "Open Sheet", target: controller, action: #selector(Controller.openSheet(_:)))
openSheet.frame = NSRect(x: 40, y: 160, width: 140, height: 32)
let openAlert = NSButton(title: "Open Alert", target: controller, action: #selector(Controller.openAlert(_:)))
openAlert.frame = NSRect(x: 220, y: 160, width: 140, height: 32)
window.contentView!.addSubview(openSheet)
window.contentView!.addSubview(openAlert)
window.makeKeyAndOrderFront(nil)

let swiftUIWindow = NSWindow(contentRect: NSRect(x: 680, y: 300, width: 360, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
swiftUIWindow.title = "SwiftUI Alert"
swiftUIWindow.isReleasedWhenClosed = false
swiftUIWindow.contentView = NSHostingView(rootView: AlertView())
swiftUIWindow.orderFront(nil)

log("ready")
app.run()
