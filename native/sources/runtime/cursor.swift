import AppKit
import PeekabooAutomationKit
import PeekabooFoundation
import QuartzCore

/// Draws the agent's own pointer, since background input never moves the real one.
///
/// Peekaboo awaits each call before dispatching the input, so a call returns once the cursor arrives
/// and the click, scroll, or drag effect then plays alongside the delivered input. Points are global
/// Core Graphics coordinates: top-left origin on the primary display, in points.
@MainActor
final class AgentCursor: AutomationFeedbackClient {
	static let shared = AgentCursor()

	private static let tint = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
	private static let secondary = NSColor(srgbRed: 0.38, green: 0.62, blue: 1, alpha: 1).cgColor
	private static let idle: Duration = .seconds(3)

	/// Off until an embedding app turns it on with `desktop_tools_set_cursor`.
	var enabled = false {
		didSet { if !enabled { reset() } }
	}

	private var overlays: [Overlay] = []
	private var position: CGPoint?
	private var fade: Task<Void, Never>?

	private init() {
		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { _ in
			MainActor.assumeIsolated { AgentCursor.shared.discard() }
		}
	}

	func showClickFeedback(at point: CGPoint, type: ClickType, target _: VisualizerTargetWindow?) async -> Bool {
		guard await travel(to: point) else { return false }
		let count = switch type {
		case .double: 2
		case .triple: 3
		default: 1
		}
		press(for: type == .longPress ? 1.2 : 0.16)
		for index in 0..<count {
			ripple(at: point, color: type == .right ? Self.secondary : Self.tint, dashed: type == .right,
				delay: Double(index) * 0.12)
		}
		rest()
		return true
	}

	func showScrollFeedback(
		at point: CGPoint, direction: ScrollDirection, amount _: Int, target _: VisualizerTargetWindow?
	) async -> Bool {
		guard await travel(to: point) else { return false }
		chevrons(at: point, direction: direction)
		rest()
		return true
	}

	func showSwipeGesture(
		from: CGPoint, to: CGPoint, duration: TimeInterval, target _: VisualizerTargetWindow?
	) async -> Bool {
		guard await travel(to: from) else { return false }
		drag(from: from, to: to, duration: duration)
		return true
	}

	func showMouseMovement(
		from _: CGPoint, to: CGPoint, duration _: TimeInterval, target _: VisualizerTargetWindow?
	) async -> Bool {
		guard await travel(to: to) else { return false }
		rest()
		return true
	}

	/// Hides the cursor at once.
	private func reset() {
		fade?.cancel()
		fade = nil
		discard()
		position = nil
	}

	// MARK: Motion

	/// Moves the cursor from where it stopped along a gentle curve, taking 250–400 ms by distance.
	private func travel(to point: CGPoint) async -> Bool {
		guard enabled else { return false }
		fade?.cancel()
		if overlays.isEmpty { overlays = NSScreen.screens.map(Overlay.init) }
		let start = currentPosition() ?? realPointer() ?? point
		position = point
		let distance = hypot(point.x - start.x, point.y - start.y)
		let duration = 0.25 + min(distance / 1600, 1) * 0.15
		let path = Self.curve(from: start, to: point)
		for overlay in overlays {
			overlay.show()
			let motion = CAKeyframeAnimation(keyPath: "position")
			motion.path = path.copy(using: [overlay.transform])
			motion.duration = duration
			motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			motion.calculationMode = .paced
			overlay.place(at: point)
			overlay.cursor.add(motion, forKey: "travel")
		}
		try? await Task.sleep(for: .seconds(duration))
		return true
	}

	/// Peekaboo's agent-cursor path: a quadratic Bézier bent to one side by up to 54 points.
	private static func curve(from: CGPoint, to: CGPoint) -> CGPath {
		let dx = to.x - from.x, dy = to.y - from.y
		let distance = max(hypot(dx, dy), 1)
		let bend = min(max(distance * 0.09, 12), 54)
		let control = CGPoint(x: (from.x + to.x) / 2 - dy / distance * bend, y: (from.y + to.y) / 2 + dx / distance * bend)
		let path = CGMutablePath()
		path.move(to: from)
		path.addQuadCurve(to: to, control: control)
		return path
	}

	private func currentPosition() -> CGPoint? {
		guard position != nil, let overlay = overlays.first, overlay.isVisible else { return nil }
		let shown = overlay.cursor.presentation()?.position ?? overlay.cursor.position
		return shown.applying(overlay.transform.inverted())
	}

	private func realPointer() -> CGPoint? {
		guard let primary = NSScreen.screens.first else { return nil }
		let location = NSEvent.mouseLocation
		return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
	}

	/// Fades the cursor out once no input has arrived for a few seconds.
	private func rest(after extra: TimeInterval = 0) {
		fade?.cancel()
		fade = Task { [weak self] in
			try? await Task.sleep(for: Self.idle + .seconds(extra))
			guard !Task.isCancelled, let self else { return }
			for overlay in self.overlays { overlay.fadeOut() }
		}
	}

	private func discard() {
		for overlay in overlays { overlay.close() }
		overlays = []
	}

	// MARK: Effects

	private func press(for duration: TimeInterval) {
		let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
		squeeze.values = [1, 0.82, 0.82, 1]
		squeeze.keyTimes = [0, 0.25, 0.75, 1]
		squeeze.duration = max(duration, 0.16)
		for overlay in overlays { overlay.cursor.add(squeeze, forKey: "press") }
	}

	private func ripple(at point: CGPoint, color: CGColor, dashed: Bool, delay: TimeInterval) {
		for overlay in overlays {
			let ring = CAShapeLayer()
			ring.path = CGPath(ellipseIn: CGRect(x: -18, y: -18, width: 36, height: 36), transform: nil)
			ring.fillColor = color.copy(alpha: 0.18)
			ring.strokeColor = color
			ring.lineWidth = 2.5
			if dashed { ring.lineDashPattern = [5, 4] }
			ring.opacity = 0
			overlay.effect(ring, at: point)
			let grow = CABasicAnimation(keyPath: "transform.scale")
			grow.fromValue = 0.35
			grow.toValue = 1.6
			let vanish = CABasicAnimation(keyPath: "opacity")
			vanish.fromValue = 0.95
			vanish.toValue = 0
			let group = CAAnimationGroup()
			group.animations = [grow, vanish]
			group.duration = 0.5
			group.beginTime = CACurrentMediaTime() + delay
			group.timingFunction = CAMediaTimingFunction(name: .easeOut)
			overlay.expire(ring, after: 0.5 + delay, animation: group)
		}
	}

	private func chevrons(at point: CGPoint, direction: ScrollDirection) {
		let (dx, dy): (CGFloat, CGFloat) = switch direction {
		case .up: (0, -1)
		case .down: (0, 1)
		case .left: (-1, 0)
		case .right: (1, 0)
		}
		// A chevron pointing down in a top-left-origin layer, rotated to the scroll direction.
		let glyph = CGMutablePath()
		for offset: CGFloat in [-5, 2] {
			glyph.move(to: CGPoint(x: -7, y: offset - 3))
			glyph.addLine(to: CGPoint(x: 0, y: offset + 3))
			glyph.addLine(to: CGPoint(x: 7, y: offset - 3))
		}
		let angle = atan2(dy, dx) - .pi / 2
		let anchor = CGPoint(x: point.x + dx * 30 + 14, y: point.y + dy * 30 + 10)
		for overlay in overlays {
			let layer = CAShapeLayer()
			layer.path = glyph
			layer.fillColor = nil
			layer.strokeColor = Self.tint
			layer.lineWidth = 3
			layer.lineCap = .round
			layer.lineJoin = .round
			layer.shadowColor = Self.tint
			layer.shadowOpacity = 0.8
			layer.shadowRadius = 4
			layer.shadowOffset = .zero
			layer.opacity = 0
			layer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
			overlay.effect(layer, at: anchor)
			let slide = CABasicAnimation(keyPath: "position")
			slide.fromValue = layer.position
			slide.toValue = CGPoint(x: layer.position.x + dx * 12, y: layer.position.y + dy * 12)
			let pulse = CAKeyframeAnimation(keyPath: "opacity")
			pulse.values = [0, 1, 1, 0]
			pulse.keyTimes = [0, 0.2, 0.6, 1]
			let group = CAAnimationGroup()
			group.animations = [slide, pulse]
			group.duration = 0.6
			overlay.expire(layer, after: 0.6, animation: group)
		}
	}

	private func drag(from: CGPoint, to: CGPoint, duration: TimeInterval) {
		let line = CGMutablePath()
		line.move(to: from)
		line.addLine(to: to)
		position = to
		press(for: duration + 0.1)
		for overlay in overlays {
			let trail = CAShapeLayer()
			trail.path = line.copy(using: [overlay.transform])
			trail.fillColor = nil
			trail.strokeColor = Self.tint.copy(alpha: 0.85)
			trail.lineWidth = 3
			trail.lineCap = .round
			trail.lineDashPattern = [1, 7]
			trail.shadowColor = Self.tint
			trail.shadowOpacity = 0.6
			trail.shadowRadius = 3
			trail.shadowOffset = .zero
			overlay.trail(trail)
			let draw = CABasicAnimation(keyPath: "strokeEnd")
			draw.fromValue = 0
			draw.toValue = 1
			draw.duration = duration
			let linger = CAKeyframeAnimation(keyPath: "opacity")
			linger.values = [1, 1, 0]
			linger.keyTimes = [0, NSNumber(value: duration / (duration + 0.8)), 1]
			let group = CAAnimationGroup()
			group.animations = [draw, linger]
			group.duration = duration + 0.8
			overlay.expire(trail, after: duration + 0.8, animation: group)

			let motion = CABasicAnimation(keyPath: "position")
			motion.fromValue = from.applying(overlay.transform)
			motion.toValue = to.applying(overlay.transform)
			motion.duration = duration
			overlay.place(at: to)
			overlay.cursor.add(motion, forKey: "travel")
		}
		rest(after: duration)
	}
}

/// One click-through panel per display; each draws the same scene clipped to its screen.
@MainActor
private final class Overlay {
	private final class Panel: NSPanel {
		override var canBecomeKey: Bool { false }
		override var canBecomeMain: Bool { false }
	}

	let cursor = CALayer()
	/// Maps global Core Graphics points into this panel's top-left-origin layer space.
	let transform: CGAffineTransform
	private let panel: Panel
	private let root = CALayer()
	private let effects = CALayer()

	init(_ screen: NSScreen) {
		let primary = NSScreen.screens.first?.frame ?? screen.frame
		transform = CGAffineTransform(
			translationX: -screen.frame.minX, y: -(primary.maxY - screen.frame.maxY))
		panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered, defer: false)
		panel.level = .screenSaver
		panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
		panel.ignoresMouseEvents = true
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.animationBehavior = .none
		// Our own captures and screen sharing never show the agent's cursor.
		panel.sharingType = .none
		panel.setFrame(screen.frame, display: false)

		let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
		view.wantsLayer = true
		root.isGeometryFlipped = true
		root.frame = view.bounds
		view.layer?.addSublayer(root)
		effects.frame = root.bounds
		root.addSublayer(effects)
		root.addSublayer(cursor)
		panel.contentView = view
		Self.draw(cursor, scale: screen.backingScaleFactor)
	}

	var isVisible: Bool { panel.isVisible && cursor.opacity > 0 }

	/// The arrow's tip is the layer's anchor, so scaling presses toward the hotspot.
	private static func draw(_ cursor: CALayer, scale: CGFloat) {
		let arrow = CGMutablePath()
		let points: [(CGFloat, CGFloat)] = [
			(0, 0), (0, 17.5), (4.2, 13.6), (7, 19.8), (9.8, 18.6), (7, 12.5), (12.6, 12.5),
		]
		arrow.addLines(between: points.map { CGPoint(x: $0.0 * 1.25, y: $0.1 * 1.25) })
		arrow.closeSubpath()
		cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 26)
		cursor.anchorPoint = .zero
		cursor.opacity = 0
		let shape = CAShapeLayer()
		shape.path = arrow
		shape.fillColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
		shape.strokeColor = .white
		shape.lineWidth = 1.5
		shape.lineJoin = .round
		shape.contentsScale = scale
		shape.shadowColor = shape.fillColor
		shape.shadowOpacity = 0.9
		shape.shadowRadius = 7
		shape.shadowOffset = .zero
		cursor.addSublayer(shape)
	}

	func show() {
		panel.orderFrontRegardless()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		cursor.removeAnimation(forKey: "fade")
		cursor.opacity = 1
		CATransaction.commit()
	}

	func place(at point: CGPoint) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		cursor.position = point.applying(transform)
		CATransaction.commit()
	}

	func effect(_ layer: CALayer, at point: CGPoint) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.position = point.applying(transform)
		effects.addSublayer(layer)
		CATransaction.commit()
	}

	func trail(_ layer: CALayer) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		effects.addSublayer(layer)
		CATransaction.commit()
	}

	/// Plays a one-shot effect, then removes its layer.
	func expire(_ layer: CALayer, after seconds: TimeInterval, animation: CAAnimation) {
		animation.fillMode = .backwards
		layer.add(animation, forKey: "effect")
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(seconds + 0.05))
			layer.removeFromSuperlayer()
		}
	}

	func fadeOut() {
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = cursor.presentation()?.opacity ?? 1
		fade.toValue = 0
		fade.duration = 0.4
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		CATransaction.setCompletionBlock { [panel, cursor] in
			MainActor.assumeIsolated {
				if cursor.opacity == 0 { panel.orderOut(nil) }
			}
		}
		cursor.opacity = 0
		cursor.add(fade, forKey: "fade")
		CATransaction.commit()
	}

	func close() {
		panel.orderOut(nil)
		panel.close()
	}
}
