import AppKit
// The parity fixture for the Swift spike: a button, a text field, a pad that logs every mouse event to stdout, and a
// scrolling text view. Build it with `swiftc -O native2/fixture/main.swift -o native2/.build/fixture`.
final class LogView: NSView {
	override func mouseDown(with e: NSEvent) { log("mouseDown \(e.clickCount) \(e.locationInWindow)") }
	override func mouseUp(with e: NSEvent) { log("mouseUp \(e.clickCount) drags=\(drags) \(e.locationInWindow)"); drags = 0 }
	override func rightMouseDown(with e: NSEvent) { log("rightMouseDown") }
	override func otherMouseDown(with e: NSEvent) { log("otherMouseDown \(e.buttonNumber)") }
	var drags = 0
	override func mouseDragged(with e: NSEvent) { drags += 1; log("mouseDragged \(drags) \(e.locationInWindow)") }
	override func rightMouseDragged(with e: NSEvent) { drags += 1; log("rightMouseDragged \(drags)") }
	override func rightMouseUp(with e: NSEvent) { log("rightMouseUp drags=\(drags)"); drags = 0 }
	override func scrollWheel(with e: NSEvent) { log("scrollWheel \(e.scrollingDeltaY) \(e.scrollingDeltaX)") }
	override func draw(_ r: NSRect) { NSColor.systemTeal.setFill(); r.fill() }
	override var acceptsFirstResponder: Bool { true }
	override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
func log(_ s: String) { print(s); fflush(stdout); label.stringValue = s }
let label = NSTextField(labelWithString: "ready")
final class Target: NSObject { var n = 0; @objc func press() { n += 1; log("button \(n)") } }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Click Fixture"
let target = Target()
let button = NSButton(title: "Press me", target: target, action: #selector(Target.press))
button.frame = NSRect(x: 20, y: 200, width: 120, height: 32)
let field = NSTextField(frame: NSRect(x: 160, y: 204, width: 220, height: 24))
field.placeholderString = "field"
let pad = LogView(frame: NSRect(x: 20, y: 50, width: 380, height: 130))
label.frame = NSRect(x: 20, y: 15, width: 380, height: 24)
let scroll = NSTextView.scrollableTextView()
scroll.frame = NSRect(x: 420, y: 15, width: 200, height: 220)
(scroll.documentView as! NSTextView).string = (1...200).map { "line \($0)" }.joined(separator: "\n")
for v in [button, field, pad, label, scroll] { window.contentView!.addSubview(v) }
window.makeKeyAndOrderFront(nil)
app.run()
