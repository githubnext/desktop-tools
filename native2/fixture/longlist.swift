import AppKit
// The long list fixture (#249): a scroll area whose content is a stack of 400 rows, every one of them an
// Accessibility child of the stack whether or not it is scrolled into view, scrolled at launch past its first 190
// rows (the stack's spacing puts about row 209 at the top). An inspection must list the rows on screen though
// hundreds of off-screen siblings come before them. Build it with `swiftc -O native2/fixture/longlist.swift -o native2/.build/longlist`; pass a row number to scroll elsewhere.

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: "longlist")
appItem.submenu!.addItem(withTitle: "Quit longlist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 360, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Long List"
let stack = NSStackView()
stack.orientation = .vertical
stack.alignment = .leading
stack.spacing = 0
stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
let rowHeight: CGFloat = 28
for index in 0..<400 {
	let row = NSButton(title: "Row \(index)", target: nil, action: nil)
	row.bezelStyle = .inline
	row.translatesAutoresizingMaskIntoConstraints = false
	row.heightAnchor.constraint(equalToConstant: rowHeight - 4).isActive = true
	stack.addArrangedSubview(row)
	stack.setCustomSpacing(4, after: row)
}
let flipped = FlippedView()
flipped.addSubview(stack)
stack.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([
	stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
	stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
])
let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.autoresizingMask = [.width, .height]
scroll.hasVerticalScroller = true
scroll.documentView = flipped
flipped.translatesAutoresizingMaskIntoConstraints = false
flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
window.contentView!.addSubview(scroll)
window.makeKeyAndOrderFront(nil)
window.layoutIfNeeded()

let top = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 190
if let target = stack.arrangedSubviews.dropFirst(top).first {
	scroll.contentView.scroll(to: NSPoint(x: 0, y: target.frame.minY))
	scroll.reflectScrolledClipView(scroll.contentView)
}
print("ready, row \(top) at the top")
fflush(stdout)
app.run()

final class FlippedView: NSView {
	override var isFlipped: Bool { true }
}
