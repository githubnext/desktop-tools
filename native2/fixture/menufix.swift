import AppKit
// The menus lane's fixture: a custom main menu, alerts, a sheet, Open and Save panels, a status item and a password
// field, logging every command to stdout. Build it with
// `swiftc -O native2/fixture/menufix.swift -o native2/.build/menufix`; the process and Dock title are "menufix".
func log(_ s: String) { print(s); fflush(stdout); label.stringValue = s }
let label = NSTextField(labelWithString: "ready")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 520, height: 220), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Menu Fixture"
window.isReleasedWhenClosed = false

final class Target: NSObject, NSMenuItemValidation {
	@objc func command(_ sender: NSMenuItem) { log("menu \(sender.title)") }
	@objc func alert(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Fixture Alert"
		alert.informativeText = "Choose one."
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Don’t Save")
		DispatchQueue.main.async { log("alert \(alert.runModal().rawValue)") }
	}
	@objc func sheet(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Fixture Sheet"
		alert.informativeText = "Type a name."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
		input.placeholderString = "Name"
		alert.accessoryView = input
		alert.beginSheetModal(for: window) { log("sheet \($0.rawValue) \(input.stringValue)") }
	}
	@objc func open(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.beginSheetModal(for: window) { log("open \($0.rawValue) \(panel.url?.path ?? "-")") }
	}
	@objc func save(_ sender: Any?) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "fixture.txt"
		panel.begin { log("save \($0.rawValue) \(panel.url?.path ?? "-")") }
	}
	@objc func status(_ sender: NSMenuItem) { log("status \(sender.title)") }
	func validateMenuItem(_ item: NSMenuItem) -> Bool { item.title != "Disabled Item" }
}
let target = Target()

func item(_ title: String, _ action: Selector = #selector(Target.command(_:)), key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
	let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
	item.keyEquivalentModifierMask = modifiers
	item.target = target
	return item
}
func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
	let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
	let menu = NSMenu(title: title)
	menu.autoenablesItems = true
	items.forEach(menu.addItem)
	top.submenu = menu
	return top
}
let main = NSMenu()
main.addItem(menu("menufix", [NSMenuItem(title: "Quit menufix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]))
let more = menu("More", [item("Leaf A"), item("Leaf B", key: "b", modifiers: [.command, .shift])])
main.addItem(menu("Fixture", [
	item("Plain"), item("Save…", key: "s"), item("Disabled Item"), .separator(), more, item("Twin"), item("Twin"),
	item("Show Alert", #selector(Target.alert(_:))), item("Show Sheet", #selector(Target.sheet(_:))),
	item("Show Open Panel", #selector(Target.open(_:))), item("Show Save Panel", #selector(Target.save(_:))),
]))
let edit = menu("Edit", [
	NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
	NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
	NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
])
main.addItem(edit)
app.mainMenu = main

let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
status.button?.title = "MFX"
let statusMenu = NSMenu()
let statusItem = NSMenuItem(title: "Status A", action: #selector(Target.status(_:)), keyEquivalent: "")
statusItem.target = target
statusMenu.addItem(statusItem)
status.menu = statusMenu

let field = NSTextField(frame: NSRect(x: 20, y: 150, width: 220, height: 24))
field.placeholderString = "plain"
let secure = NSSecureTextField(frame: NSRect(x: 260, y: 150, width: 220, height: 24))
secure.placeholderString = "password"
label.frame = NSRect(x: 20, y: 20, width: 480, height: 24)
for v in [field, secure, label] { window.contentView!.addSubview(v) }
window.makeKeyAndOrderFront(nil)
// Dialogs can also be opened by writing a command to /tmp/menufix.cmd, which needs no input while the
// session is locked: alert, sheet, open, save, or secure (focus the password field).
let commands: [String: () -> Void] = [
	"alert": { target.alert(nil) }, "sheet": { target.sheet(nil) }, "open": { target.open(nil) },
	"save": { target.save(nil) }, "secure": { window.makeFirstResponder(secure) },
]
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
	let path = "/tmp/menufix.cmd"
	guard let command = try? String(contentsOfFile: path, encoding: .utf8) else { return }
	try? FileManager.default.removeItem(atPath: path)
	commands[command.trimmingCharacters(in: .whitespacesAndNewlines)]?()
}
app.run()
