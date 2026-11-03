import AppKit
import SwiftUI
// The keyboard fixture (#226): an AppKit table and a SwiftUI List, each in its own window, that take Delete and
// Return only as views, never through the menu bar. Every key a view receives, every delete and rename, and every
// key-window change is logged to stdout with the window's key state and first responder. Build it with
// `swiftc -O native2/fixture/keysfix.swift -o native2/.build/keysfix`; the process and Dock title are "keysfix".
func log(_ s: String) { print(s); fflush(stdout) }
func responder(_ window: NSWindow?) -> String {
	guard let window else { return "none" }
	return window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
}

final class Table: NSTableView {
	var names = ["alpha", "beta", "gamma", "delta"]
	override func keyDown(with event: NSEvent) {
		log("table key \(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") key=\(window?.isKeyWindow ?? false) active=\(NSApp.isActive)")
		switch event.keyCode {
		case 0x33, 0x75:
			guard selectedRow >= 0 else { return super.keyDown(with: event) }
			log("table deleted \(names.remove(at: selectedRow))")
			reloadData()
		case 0x24:
			if selectedRow >= 0 { log("table rename \(names[selectedRow])") }
		default: super.keyDown(with: event)
		}
	}
}

final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
	let table: Table
	init(_ table: Table) { self.table = table }
	func numberOfRows(in tableView: NSTableView) -> Int { table.names.count }
	func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? { table.names[row] }
	func tableViewSelectionDidChange(_ notification: Notification) { log("table selected \(table.selectedRow)") }
}

final class Model: ObservableObject {
	@Published var items = ["one", "two", "three", "four"]
	@Published var selection: Set<String> = []
}

struct ListView: View {
	@ObservedObject var model: Model
	var body: some View {
		List(model.items, id: \.self, selection: $model.selection) { item in
			Text(item)
		}
		.onDeleteCommand {
			log("list deleted \(model.selection.sorted())")
			model.items.removeAll { model.selection.contains($0) }
			model.selection = []
		}
		.onChange(of: model.selection) { _, value in log("list selected \(value.sorted())") }
	}
}

final class Watcher: NSObject, NSWindowDelegate {
	func windowDidBecomeKey(_ notification: Notification) {
		let window = notification.object as! NSWindow
		log("key \(window.title) responder=\(responder(window)) active=\(NSApp.isActive)")
	}
	func windowDidResignKey(_ notification: Notification) { log("resign \((notification.object as! NSWindow).title)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let watcher = Watcher()

let tableWindow = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 360, height: 260), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
tableWindow.title = "Keys Table"
tableWindow.isReleasedWhenClosed = false
tableWindow.delegate = watcher
let table = Table()
let column = NSTableColumn(identifier: .init("name"))
column.title = "Name"
column.width = 300
column.isEditable = false
table.addTableColumn(column)
table.setAccessibilityLabel("Rows")
let rows = Rows(table)
table.dataSource = rows
table.delegate = rows
let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 320, height: 180))
scroll.documentView = table
let field = NSTextField(frame: NSRect(x: 20, y: 216, width: 320, height: 24))
field.placeholderString = "filter"
field.setAccessibilityLabel("Filter")
tableWindow.contentView!.addSubview(scroll)
tableWindow.contentView!.addSubview(field)

let model = Model()
let listWindow = NSWindow(contentRect: NSRect(x: 600, y: 300, width: 300, height: 260), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
listWindow.title = "Keys List"
listWindow.isReleasedWhenClosed = false
listWindow.delegate = watcher
listWindow.contentView = NSHostingView(rootView: ListView(model: model))

NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in log("app active") }
NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in log("app inactive") }

// `keysfix list` makes the List's window the app's main and focused one instead of the table's.
if CommandLine.arguments.dropFirst().first == "list" {
	tableWindow.orderFront(nil)
	listWindow.makeKeyAndOrderFront(nil)
} else {
	listWindow.orderFront(nil)
	tableWindow.makeKeyAndOrderFront(nil)
}
tableWindow.makeFirstResponder(table)
log("ready table=\(tableWindow.windowNumber) list=\(listWindow.windowNumber)")
app.run()
