import AppKit
// The pointer lane's fixture: a pad that logs presses with their modifiers and hold times, a text source to drag,
// and a second window that accepts the drop. Build it with
// `swiftc -O native2/fixture/pointer.swift -o native2/.build/pointerfix`.
func flags(_ e: NSEvent) -> String {
	let names: [(NSEvent.ModifierFlags, String)] = [(.command, "command"), (.option, "option"), (.shift, "shift"), (.control, "control")]
	let held = names.filter { e.modifierFlags.contains($0.0) }.map(\.1)
	return held.isEmpty ? "none" : held.joined(separator: "+")
}
func log(_ s: String) { print(s); fflush(stdout); label.stringValue = s }
final class Pad: NSView {
	var downAt = Date()
	var drags = 0
	override func mouseDown(with e: NSEvent) { downAt = Date(); log("mouseDown \(e.clickCount) \(flags(e))") }
	override func mouseDragged(with e: NSEvent) { drags += 1 }
	override func mouseUp(with e: NSEvent) {
		log("mouseUp \(e.clickCount) \(flags(e)) held=\(Int(Date().timeIntervalSince(downAt) * 1000)) drags=\(drags)")
		drags = 0
	}
	override func rightMouseDown(with e: NSEvent) { downAt = Date(); log("rightMouseDown \(flags(e))") }
	override func rightMouseUp(with e: NSEvent) { log("rightMouseUp held=\(Int(Date().timeIntervalSince(downAt) * 1000))") }
	override func draw(_ r: NSRect) { NSColor.systemOrange.setFill(); r.fill() }
	override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
final class Source: NSView, NSDraggingSource {
	override func mouseDown(with e: NSEvent) { log("source mouseDown \(flags(e))") }
	override func mouseDragged(with e: NSEvent) {
		let item = NSDraggingItem(pasteboardWriter: "pointer-fixture-text" as NSString)
		item.setDraggingFrame(bounds, contents: nil)
		beginDraggingSession(with: [item], event: e, source: self)
	}
	func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
	override func draw(_ r: NSRect) { NSColor.systemPurple.setFill(); r.fill() }
	override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
final class Drop: NSView {
	override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.string]) }
	required init?(coder: NSCoder) { nil }
	override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
	override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
		log("drop \(s.draggingPasteboard.string(forType: .string) ?? "?")")
		return true
	}
	override func draw(_ r: NSRect) { NSColor.systemGreen.setFill(); r.fill() }
}
let label = NSTextField(labelWithString: "ready")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let main = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 420, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
main.title = "Pointer Fixture"
let pad = Pad(frame: NSRect(x: 20, y: 60, width: 240, height: 140))
let source = Source(frame: NSRect(x: 290, y: 60, width: 110, height: 140))
label.frame = NSRect(x: 20, y: 20, width: 380, height: 24)
for v in [pad, source, label] { main.contentView!.addSubview(v) }
let second = NSWindow(contentRect: NSRect(x: 580, y: 160, width: 260, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
second.title = "Pointer Target"
second.contentView!.addSubview(Drop(frame: NSRect(x: 20, y: 20, width: 220, height: 180)))
main.makeKeyAndOrderFront(nil)
second.orderFront(nil)
app.run()
