import AppKit
// The text tools' parity fixture: a text field, a text view, a secure field, an editable table, a date picker, a
// checkbox and a slider. Build it with `swiftc -O native2/fixture/textfix.swift -o native2/.build/textfix`.
final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
	var names = ["alpha", "beta", "gamma"]
	var done = [false, true, false]
	func numberOfRows(in tableView: NSTableView) -> Int { names.count }
	func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
		if column?.identifier.rawValue == "done" {
			let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
			box.state = done[row] ? .on : .off
			box.tag = row
			return box
		}
		let field = NSTextField(string: names[row])
		field.isBordered = false
		field.drawsBackground = false
		field.tag = row
		field.target = self
		field.action = #selector(edit(_:))
		return field
	}
	@objc func toggle(_ sender: NSButton) { done[sender.tag] = sender.state == .on; print("done \(sender.tag) \(done[sender.tag])"); fflush(stdout) }
	@objc func edit(_ sender: NSTextField) { names[sender.tag] = sender.stringValue; print("name \(sender.tag) \(sender.stringValue)"); fflush(stdout) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 260, y: 240, width: 660, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Text Fixture"
let content = window.contentView!
let field = NSTextField(frame: NSRect(x: 20, y: 316, width: 220, height: 24))
field.placeholderString = "name"
field.setAccessibilityLabel("Plain field")
field.stringValue = "hello world"
let secure = NSSecureTextField(frame: NSRect(x: 260, y: 316, width: 180, height: 24))
secure.placeholderString = "password"
secure.setAccessibilityLabel("Password field")
let checkbox = NSButton(checkboxWithTitle: "Remember me", target: nil, action: nil)
checkbox.frame = NSRect(x: 460, y: 316, width: 180, height: 24)
let slider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
slider.frame = NSRect(x: 20, y: 276, width: 220, height: 24)
let picker = NSDatePicker(frame: NSRect(x: 260, y: 276, width: 200, height: 24))
picker.datePickerElements = [.yearMonthDay]
picker.dateValue = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
let notes = NSTextView.scrollableTextView()
notes.frame = NSRect(x: 20, y: 20, width: 300, height: 240)
(notes.documentView as! NSTextView).string = "The quick brown fox\njumps over the lazy dog.\nThe end."
let rows = Rows()
let table = NSTableView()
for (id, title, width) in [("name", "Name", 160.0), ("done", "Done", 60.0)] {
	let column = NSTableColumn(identifier: .init(id))
	column.title = title
	column.width = width
	table.addTableColumn(column)
}
table.dataSource = rows
table.delegate = rows
let tableScroll = NSScrollView(frame: NSRect(x: 340, y: 20, width: 300, height: 240))
tableScroll.documentView = table
tableScroll.hasVerticalScroller = true
for view in [field, secure, checkbox, slider, picker, notes, tableScroll] { content.addSubview(view) }
// Paste and select all are key equivalents of the Edit menu, so a window without one ignores Command-V.
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu!.addItem(withTitle: "Quit textfix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem()
editItem.submenu = NSMenu(title: "Edit")
for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
	editItem.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
}
menu.addItem(appItem)
menu.addItem(editItem)
app.mainMenu = menu
window.makeKeyAndOrderFront(nil)
app.run()
