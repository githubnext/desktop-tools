import AppKit
import CoreGraphics
import Darwin
import QuartzCore

/// Outlines the window the agent is observing or acting on, with a label naming the agent and the app.
///
/// The Bridge reports each request's exact window before dispatch. The outline follows that window's frame,
/// sits directly above it in the window order so anything covering the window covers the outline too, hides
/// while the window is minimized, off screen, or on another Space, and fades out once requests stop.
@MainActor
final class AgentWindow {
	static let shared = AgentWindow()

	private static let tint = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
	/// The tint darkened, to edge the label.
	private static let rim = NSColor(srgbRed: 0.55, green: 0.27, blue: 0.18, alpha: 1).cgColor
	private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
	private static let idle: Duration = .seconds(4)
	/// Room around the window for the outline and the label that straddles its bottom edge.
	private static let margin: CGFloat = 16

	/// Off until an embedding app turns it on with `desktop_tools_set_highlight`.
	var enabled = false {
		didSet { if !enabled { reset() } }
	}

	private var target: CGWindowID?
	private var overlay: Overlay?
	private var tracking: Timer?
	private var fade: Task<Void, Never>?

	/// Shows the outline on `window` and restarts the idle fade.
	func target(window: CGWindowID, process: pid_t, agent: String?) {
		guard enabled else { return }
		let app = NSRunningApplication(processIdentifier: process)?.localizedName ?? "an app"
		let label = "\(agent ?? "Agent") is using \(app)"
		if target != window || overlay == nil {
			overlay?.close()
			overlay = Overlay(label: label)
			target = window
		} else {
			overlay?.label = label
		}
		overlay?.present()
		track()
		fade?.cancel()
		fade = Task { [weak self] in
			try? await Task.sleep(for: Self.idle)
			guard !Task.isCancelled, let self else { return }
			self.overlay?.fadeOut { [weak self] in self?.reset() }
		}
	}

	private func reset() {
		fade?.cancel()
		fade = nil
		tracking?.invalidate()
		tracking = nil
		overlay?.close()
		overlay = nil
		target = nil
	}

	/// Polls the window's frame and order at display rate while the outline is up.
	private func track() {
		update()
		guard tracking == nil else { return }
		let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
			MainActor.assumeIsolated { AgentWindow.shared.update() }
		}
		RunLoop.main.add(timer, forMode: .common)
		tracking = timer
	}

	private func update() {
		guard let target, let overlay else { return }
		guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], target) as? [[String: Any]])?.first
		else { return reset() }
		var bounds = CGRect.null
		if let frame = info[kCGWindowBounds as String] as? NSDictionary {
			bounds = CGRect(dictionaryRepresentation: frame) ?? .null
		}
		let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
		let visible = NSScreen.screens.contains { Self.flipped($0.frame).intersects(bounds) }
		guard onScreen, visible, !bounds.isEmpty else { return overlay.conceal() }
		// The display showing most of the window keeps the outline and label on it when the window fills it.
		let screen = NSScreen.screens.max { area(of: $0) < area(of: $1) }?.frame ?? .null
		func area(of screen: NSScreen) -> CGFloat {
			let shared = Self.flipped(screen.frame).intersection(bounds)
			return shared.isNull ? 0 : shared.width * shared.height
		}
		overlay.follow(target, frame: Self.flipped(bounds.insetBy(dx: -Self.margin, dy: -Self.margin)),
			screen: screen, level: info[kCGWindowLayer as String] as? Int ?? 0)
	}

	/// Converts between Cocoa screen frames (bottom-left origin) and global Core Graphics ones; the flip is its own inverse.
	private static func flipped(_ frame: CGRect) -> CGRect {
		let primary = NSScreen.screens.first?.frame.maxY ?? 0
		return CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
	}

	// MARK: Overlay

	/// One click-through panel sized to the window plus a margin, ordered directly above it.
	@MainActor
	private final class Overlay {
		private final class Panel: NSPanel {
			override var canBecomeKey: Bool { false }
			override var canBecomeMain: Bool { false }
		}

		private let panel: Panel
		private let outline = CAShapeLayer()
		private let pill = CALayer()
		private let text = CATextLayer()
		private let root = CALayer()
		private var shown = false
		/// The Cocoa frame of the display the window is on.
		private var screen = CGRect.null

		var label: String {
			get { text.string as? String ?? "" }
			set { text.string = newValue; layout() }
		}

		init(label: String) {
			panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
				backing: .buffered, defer: false)
			panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
			panel.ignoresMouseEvents = true
			panel.isOpaque = false
			panel.backgroundColor = .clear
			panel.hasShadow = false
			panel.hidesOnDeactivate = false
			panel.isReleasedWhenClosed = false
			panel.animationBehavior = .none
			// Our own captures and screen sharing never show the outline.
			panel.sharingType = .none

			let view = NSView(frame: .zero)
			view.wantsLayer = true
			view.autoresizingMask = [.width, .height]
			root.isGeometryFlipped = true
			root.opacity = 0
			view.layer?.addSublayer(root)
			panel.contentView = view

			outline.fillColor = nil
			outline.strokeColor = AgentWindow.tint
			outline.lineWidth = 3
			outline.shadowColor = AgentWindow.tint
			outline.shadowOpacity = 0.7
			outline.shadowRadius = 6
			outline.shadowOffset = .zero
			root.addSublayer(outline)

			pill.backgroundColor = AgentWindow.tint
			pill.cornerRadius = 9
			pill.borderColor = AgentWindow.rim
			pill.borderWidth = 1
			pill.shadowColor = .black
			pill.shadowOpacity = 0.25
			pill.shadowRadius = 4
			pill.shadowOffset = .zero
			text.font = AgentWindow.labelFont
			text.fontSize = AgentWindow.labelFont.pointSize
			text.foregroundColor = .white
			text.alignmentMode = .center
			text.truncationMode = .end
			text.string = label
			pill.addSublayer(text)
			root.addSublayer(pill)
		}

		/// Fades the outline in, or cancels a fade out in progress.
		func present() {
			root.removeAnimation(forKey: "fade")
			guard root.opacity < 1 else { return }
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = root.presentation()?.opacity ?? 0
			fade.toValue = 1
			fade.duration = 0.2
			root.opacity = 1
			root.add(fade, forKey: "fade")
		}

		/// Places the panel over `window`'s frame, plus the margin, directly above it in the window order.
		func follow(_ window: CGWindowID, frame: CGRect, screen: CGRect, level: Int) {
			if panel.frame != frame || self.screen != screen {
				self.screen = screen
				panel.setFrame(frame, display: false)
				layout()
			}
			if panel.level.rawValue != level { panel.level = NSWindow.Level(rawValue: level) }
			if !shown || !isOrderedAbove(panel.windowNumber, window) {
				panel.order(.above, relativeTo: Int(window))
				shown = true
			}
		}

		func conceal() {
			guard shown else { return }
			panel.orderOut(nil)
			shown = false
		}

		func fadeOut(then done: @escaping @MainActor () -> Void) {
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = root.presentation()?.opacity ?? 1
			fade.toValue = 0
			fade.duration = 0.4
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			CATransaction.setCompletionBlock { [root] in
				MainActor.assumeIsolated { if root.opacity == 0 { done() } }
			}
			root.opacity = 0
			root.add(fade, forKey: "fade")
			CATransaction.commit()
		}

		func close() {
			panel.orderOut(nil)
			panel.close()
		}

		private func layout() {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			let size = panel.frame.size
			root.frame = CGRect(origin: .zero, size: size)
			let window = root.bounds.insetBy(dx: AgentWindow.margin, dy: AgentWindow.margin)
			// The display in the panel's flipped coordinates, inset so the whole stroke stays on it.
			let frame = panel.frame
			let display = screen.isNull ? root.bounds
				: CGRect(x: screen.minX - frame.minX, y: frame.maxY - screen.maxY, width: screen.width, height: screen.height)
					.insetBy(dx: 2, dy: 2)
			let outside = window.insetBy(dx: -2, dy: -2)
			let clamped = outside.intersection(display)
			let edge = clamped.isNull || clamped.isEmpty ? outside : clamped
			outline.path = CGPath(roundedRect: edge, cornerWidth: 14, cornerHeight: 14, transform: nil)
			let measured = (label as NSString).size(withAttributes: [.font: AgentWindow.labelFont])
			let width = min(ceil(measured.width) + 16, max(window.width - 32, 60))
			// The label straddles the bottom edge, or sits just inside it when the window reaches the display's bottom.
			let top = clamped.isNull || clamped.isEmpty ? edge.maxY - 9 : min(edge.maxY - 9, display.maxY - 20)
			pill.frame = CGRect(x: window.midX - width / 2, y: top, width: width, height: 18)
			text.frame = pill.bounds.insetBy(dx: 8, dy: 2)
			text.contentsScale = panel.backingScaleFactor
			CATransaction.commit()
		}
	}
}

/// Whether `panel` is above `window` with only this process's windows between them, so no other app's window
/// can sit between. The agent cursor and the window outline both order themselves above the same window.
@MainActor
func isOrderedAbove(_ panel: Int, _ window: CGWindowID) -> Bool {
	guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], window) as? [[String: Any]]
	else { return false }
	let own = Int(getpid())
	// Nearest first: the list runs from the front down to just above `window`.
	for info in above.reversed() {
		if info[kCGWindowNumber as String] as? Int == panel { return true }
		guard info[kCGWindowOwnerPID as String] as? Int == own else { return false }
	}
	return false
}

/// The agent name an MCP server passed to the requesting client in `DESKTOP_TOOLS_AGENT`.
///
/// Read from the client's own environment while its request is pending; the client is our signed binary.
func agentName(of process: pid_t) -> String? {
	var mib = [CTL_KERN, KERN_PROCARGS2, process]
	var size = 0
	guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
	var buffer = [UInt8](repeating: 0, count: size)
	guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
	let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
	// argc, the executable path, NUL padding, then argv and the environment as NUL-terminated strings.
	var index = MemoryLayout<Int32>.size
	func next() -> ArraySlice<UInt8>? {
		guard index < size, let end = buffer[index..<size].firstIndex(of: 0) else { return nil }
		defer { index = end + 1 }
		return buffer[index..<end]
	}
	_ = next()
	while index < size, buffer[index] == 0 { index += 1 }
	for _ in 0..<argc { _ = next() }
	let key = Array("DESKTOP_TOOLS_AGENT=".utf8)
	while let entry = next(), !entry.isEmpty {
		guard entry.starts(with: key) else { continue }
		let name = String(decoding: entry.dropFirst(key.count), as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return name.isEmpty ? nil : String(name.prefix(40))
	}
	return nil
}
