// Ported from native/Sources/runtime's window.swift.
import AppKit
import CoreGraphics
import Darwin
import QuartzCore

/// Outlines each window an agent is observing or acting on, in that agent's color, with a label naming the agent and
/// the app.
///
/// Hooks.targetWindow reports each call's exact window before dispatch. Each agent has one outline, which follows its
/// window's frame, sits directly above it in the window order so anything covering the window covers the outline too,
/// hides while the window is minimized, off screen, or on another Space, and fades out once that agent's requests stop.
/// Agents on the same window nest their outlines and set their labels side by side.
@MainActor
final class AgentWindow {
	static let shared = AgentWindow()

	fileprivate static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
	private static let idle: Duration = .seconds(4)
	/// Room around the window for the outlines and the labels that straddle its bottom edge.
	fileprivate static let margin: CGFloat = 16

	/// Off until an embedding app turns it on with `desktop_tools_set_highlight`.
	var enabled = false {
		didSet { if !enabled { reset() } }
	}

	private final class Outline {
		let overlay: Overlay
		var target: CGWindowID
		/// When it was first shown on `target`, which orders agents sharing a window.
		var since = Date()
		var fade: Task<Void, Never>?

		init(overlay: Overlay, target: CGWindowID) {
			self.overlay = overlay
			self.target = target
		}
	}

	private var outlines: [String: Outline] = [:]
	private var tracking: Timer?

	/// Shows `agent`'s outline on `window` and restarts its idle fade.
	func target(window: CGWindowID, process: pid_t, agent: AgentIdentity) {
		guard enabled else { return }
		let app = NSRunningApplication(processIdentifier: process)?.localizedName ?? "an app"
		let label = "\(agent.name) is using \(app)"
		let outline: Outline
		if let existing = outlines[agent.key], existing.target == window {
			outline = existing
			outline.overlay.label = label
		} else {
			outlines[agent.key]?.fade?.cancel()
			outlines[agent.key]?.overlay.close()
			outline = Outline(overlay: Overlay(label: label, tint: agent.tint), target: window)
			outlines[agent.key] = outline
		}
		outline.overlay.present()
		track()
		outline.fade?.cancel()
		outline.fade = Task { [weak self, weak outline] in
			try? await Task.sleep(for: Self.idle)
			guard !Task.isCancelled, let outline else { return }
			outline.overlay.fadeOut { [weak self] in self?.remove(agent.key, outline) }
		}
	}

	private func remove(_ key: String, _ outline: Outline) {
		guard outlines[key] === outline else { return }
		outline.overlay.close()
		outlines[key] = nil
		if outlines.isEmpty {
			tracking?.invalidate()
			tracking = nil
		}
	}

	private func reset() {
		tracking?.invalidate()
		tracking = nil
		for outline in outlines.values {
			outline.fade?.cancel()
			outline.overlay.close()
		}
		outlines = [:]
	}

	/// Polls the windows' frames and order at display rate while an outline is up.
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
		var shared: [CGWindowID: [(key: String, outline: Outline)]] = [:]
		for (key, outline) in outlines { shared[outline.target, default: []].append((key, outline)) }
		for (_, group) in shared {
			let ordered = group.sorted { ($0.outline.since, $0.key) < ($1.outline.since, $1.key) }
			for (slot, entry) in ordered.enumerated() {
				entry.outline.overlay.slot = (slot, ordered.count)
				if !update(entry.outline) { remove(entry.key, entry.outline) }
			}
		}
	}

	/// False once the window is gone.
	private func update(_ outline: Outline) -> Bool {
		let target = outline.target, overlay = outline.overlay
		guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], target) as? [[String: Any]])?.first
		else { return false }
		var bounds = CGRect.null
		if let frame = info[kCGWindowBounds as String] as? NSDictionary {
			bounds = CGRect(dictionaryRepresentation: frame) ?? .null
		}
		let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
		let visible = NSScreen.screens.contains { Self.flipped($0.frame).intersects(bounds) }
		guard onScreen, visible, !bounds.isEmpty else {
			overlay.conceal()
			return true
		}
		// The display showing most of the window keeps the outline and label on it when the window fills it.
		let screen = NSScreen.screens.max { area(of: $0) < area(of: $1) }?.frame ?? .null
		func area(of screen: NSScreen) -> CGFloat {
			let shared = Self.flipped(screen.frame).intersection(bounds)
			return shared.isNull ? 0 : shared.width * shared.height
		}
		let frame = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
		let covers = Self.group(above: target, owner: info[kCGWindowOwnerPID as String] as? Int)
			.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
		overlay.follow(target, frame: Self.flipped(frame), screen: screen,
			level: info[kCGWindowLayer as String] as? Int ?? 0, covers: covers)
		return true
	}

	/// The bounds of the window's own sheets and panels stacked directly above it, such as an Open panel on a
	/// Save sheet. The window server keeps them with the window as one group, so the outline can't order between
	/// them and is cut away under them instead (#149).
	private static func group(above window: CGWindowID, owner: Int?) -> [CGRect] {
		guard let owner, let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], window) as? [[String: Any]]
		else { return [] }
		let own = Int(getpid())
		var covers: [CGRect] = []
		// Nearest first, past our own outline and cursor, up to the first other app's window.
		for info in above.reversed() {
			let pid = info[kCGWindowOwnerPID as String] as? Int
			if pid == own { continue }
			guard pid == owner else { break }
			if let frame = info[kCGWindowBounds as String] as? NSDictionary,
				let bounds = CGRect(dictionaryRepresentation: frame) { covers.append(bounds) }
		}
		return covers
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
		/// The window's own sheets and panels above it, in the panel's flipped coordinates.
		private var covers: [CGRect] = []

		/// This agent's place among the agents on the same window.
		var slot = (index: 0, count: 1) {
			didSet { if slot != oldValue { layout() } }
		}

		var label: String {
			get { text.string as? String ?? "" }
			set { text.string = newValue; layout() }
		}

		init(label: String, tint: AgentIdentity.Tint) {
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
			outline.strokeColor = tint.color
			outline.lineWidth = 3
			outline.shadowColor = tint.color
			outline.shadowOpacity = 0.7
			outline.shadowRadius = 6
			outline.shadowOffset = .zero
			root.addSublayer(outline)

			pill.backgroundColor = tint.color
			pill.cornerRadius = 9
			pill.borderColor = tint.rim
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
			if root.presentation()?.opacity ?? 0 == 0 {
				// A new outline draws itself around the window as the cursor arrives.
				let draw = CABasicAnimation(keyPath: "strokeEnd")
				draw.fromValue = 0
				draw.toValue = 1
				draw.duration = 0.16
				draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
				outline.add(draw, forKey: "draw")
			}
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = root.presentation()?.opacity ?? 0
			fade.toValue = 1
			fade.duration = 0.2
			root.opacity = 1
			root.add(fade, forKey: "fade")
		}

		/// Places the panel over `window`'s frame, plus the margin, directly above it in the window order, and cuts
		/// it away under `covers`.
		func follow(_ window: CGWindowID, frame: CGRect, screen: CGRect, level: Int, covers: [CGRect]) {
			if panel.frame != frame || self.screen != screen || self.covers != covers {
				self.screen = screen
				self.covers = covers
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
			// Each further agent on the window nests its outline 5 points out.
			let outside = window.insetBy(dx: -2 - CGFloat(slot.index) * 5, dy: -2 - CGFloat(slot.index) * 5)
			let clamped = outside.intersection(display)
			let edge = clamped.isNull || clamped.isEmpty ? outside : clamped
			outline.path = CGPath(roundedRect: edge, cornerWidth: 14, cornerHeight: 14, transform: nil)
			let measured = (label as NSString).size(withAttributes: [.font: AgentWindow.labelFont])
			let width = min(ceil(measured.width) + 16, max(window.width - 32, 60))
			// The label straddles the bottom edge, or sits just inside it when the window reaches the display's bottom.
			let top = clamped.isNull || clamped.isEmpty ? edge.maxY - 9 : min(edge.maxY - 9, display.maxY - 20)
			let spread = (CGFloat(slot.index) - CGFloat(slot.count - 1) / 2) * (width + 8)
			pill.frame = CGRect(x: window.midX - width / 2 + spread, y: top, width: width, height: 18)
			text.frame = pill.bounds.insetBy(dx: 8, dy: 2)
			text.contentsScale = panel.backingScaleFactor
			if covers.isEmpty {
				root.mask = nil
			} else {
				let cut = covers.reduce(CGPath(rect: .null, transform: nil)) { $0.union(CGPath(rect: $1, transform: nil)) }
				let mask = root.mask as? CAShapeLayer ?? CAShapeLayer()
				mask.frame = root.bounds
				mask.path = CGPath(rect: root.bounds, transform: nil).subtracting(cut)
				root.mask = mask
			}
			CATransaction.commit()
		}
	}
}

/// Whether `panel` is above `window` with only this process's windows, or the window's own sheets and panels,
/// between them, so no other app's window can sit between. The agent cursor and the window outline both order
/// themselves above the same window. The window server keeps a window's sheets with it, so ordering above the
/// window puts the panel above them too, and reordering can't do better.
@MainActor
func isOrderedAbove(_ panel: Int, _ window: CGWindowID) -> Bool {
	guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], window) as? [[String: Any]]
	else { return false }
	let owner = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?
		.first?[kCGWindowOwnerPID as String] as? Int
	let own = Int(getpid())
	// Nearest first: the list runs from the front down to just above `window`.
	for info in above.reversed() {
		if info[kCGWindowNumber as String] as? Int == panel { return true }
		let pid = info[kCGWindowOwnerPID as String] as? Int
		guard pid == own || pid == owner else { return false }
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
