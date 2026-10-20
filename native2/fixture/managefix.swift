import AppKit
// The management fixture: several resizable windows to move, resize, minimize, maximize, focus and close. A closed
// "Manage Close" window comes back after a moment so a parity run can close it again, and "Manage Keep" refuses to
// close. Bundle it as an .app with native2/fixture/managefix.sh so desktop_launch and desktop_open can reach it.
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	var windows: [NSWindow] = []
	func applicationDidFinishLaunching(_ note: Notification) {
		for (index, title) in ["Manage One", "Manage Two", "Manage Close", "Manage Keep"].enumerated() {
			open(title, at: NSPoint(x: 160 + index * 40, y: 160 + index * 40))
		}
	}
	func open(_ title: String, at origin: NSPoint) {
		let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 420, height: 260)),
		                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
		window.title = title
		window.isReleasedWhenClosed = false
		window.collectionBehavior = [.fullScreenPrimary]
		window.delegate = self
		let label = NSTextField(labelWithString: title)
		label.frame = NSRect(x: 20, y: 20, width: 300, height: 24)
		window.contentView!.addSubview(label)
		window.orderFront(nil)
		windows.append(window)
	}
	func windowShouldClose(_ sender: NSWindow) -> Bool { sender.title != "Manage Keep" }
	func windowWillClose(_ note: Notification) {
		guard let window = note.object as? NSWindow, window.title == "Manage Close" else { return }
		windows.removeAll { $0 === window }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.open("Manage Close", at: NSPoint(x: 240, y: 240)) }
	}
	func application(_ app: NSApplication, open urls: [URL]) {
		print("open \(urls)"); fflush(stdout)
		open("Opened \(urls.first?.lastPathComponent ?? "")", at: NSPoint(x: 300, y: 300))
	}
	func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
