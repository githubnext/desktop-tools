// Ported from native/Sources/runtime's cursor.swift; Peekaboo's feedback client calls became Hooks.pointer. The motion
// follows the cursor lab (native2/fixture/cursorlab), with the values tuned there.
import AppKit
import DesktopHost
import DesktopMac
import QuartzCore

/// Draws each agent's own pointer, in its color, since background input never moves the real one.
///
/// An agent's cursor peels out of the real pointer for its first input, travels along an arc, clicks, and once its
/// agent goes quiet springs back to the live pointer and merges into it. Hooks.pointer awaits `show` before the input
/// is posted, so it returns once the cursor arrives and the click, scroll, or drag effect then plays alongside the
/// delivered input; a first input waits at most `firstWait` for the breakout and travel together, well inside
/// Hooks.pointerLimit. Points are global Core Graphics coordinates: top-left origin on the primary display, in points.
@MainActor
final class AgentCursor: NSObject {
	static let shared = AgentCursor()

	/// Off until an embedding app turns it on with `desktop_tools_set_cursor`.
	var enabled = false {
		didSet { if !enabled { reset() } }
	}

	private var cursors: [String: Cursor] = [:]
	private var link: CADisplayLink?
	private var last: CFTimeInterval?

	override private init() {
		super.init()
		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { _ in
			MainActor.assumeIsolated { AgentCursor.shared.reset() }
		}
	}

	/// The exact window of an agent's latest request, which Hooks.targetWindow reports before dispatch.
	func target(_ agent: AgentIdentity, window: CGWindowID) {
		guard enabled else { return }
		cursor(for: agent).window = window
	}

	/// Plays one pointer input's feedback, returning once the agent's cursor has arrived where the input lands.
	func show(_ feedback: Hooks.PointerFeedback, agent: AgentIdentity) async {
		guard enabled else { return }
		await cursor(for: agent).show(feedback)
	}

	private func cursor(for agent: AgentIdentity) -> Cursor {
		if let cursor = cursors[agent.key] { return cursor }
		let cursor = Cursor(agent, wake: { [weak self] in self?.wake() })
		cursors[agent.key] = cursor
		return cursor
	}

	/// Hides every cursor at once.
	private func reset() {
		for cursor in cursors.values { cursor.discard() }
		cursors = [:]
		link?.isPaused = true
	}

	// MARK: Clock

	private func wake() {
		if link == nil {
			link = NSScreen.screens.first?.displayLink(target: self, selector: #selector(frame(_:)))
			link?.add(to: .main, forMode: .common)
		}
		link?.isPaused = false
	}

	@objc private func frame(_ link: CADisplayLink) {
		let dt = min(last.map { link.timestamp - $0 } ?? 1.0 / 60, 1.0 / 30)
		last = link.timestamp
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for cursor in cursors.values { cursor.step(now: CACurrentMediaTime(), dt: dt) }
		CATransaction.commit()
		// A clock left running burns CPU with nothing on screen.
		if cursors.values.allSatisfy({ !$0.isVisible }) {
			link.isPaused = true
			last = nil
		}
	}
}

/// The values tuned in the cursor lab, in seconds, points and degrees.
private enum Tuning {
	static let windup = 0.06
	static let dip = 0.12
	static let peel = 0.18
	static let peelDistance = 24.0
	static let travelShort = 0.205
	static let travelLong = 0.4
	/// The longest a first input waits for the wind-up, peel and travel together.
	static let firstWait = 0.54
	static let bend = 0.09
	static let bendMost = 54.0
	static let overshoot = 0.6
	static let stretchGain = 0.12
	static let stretchMost = 0.35
	static let tiltGain = 6.0
	static let tiltMost = 14.0
	static let tagStiffness = 600.0
	static let tagDamping = 0.7
	static let tagLag = 18.0
	static let press = 0.16
	static let pressScale = 0.82
	static let ripple = 0.4
	static let pop = 1.6
	static let homeStiffness = 170.0
	static let homeDamping = 0.75
	static let merge = 0.18
	/// How long an agent stays quiet before its cursor goes home.
	static let idle = 3.0
	/// The longest a held button can last, which is the Bridge's own limit for a hold's expiry.
	static let longestHold = 30.0
}

private enum Ease {
	static func out(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
	static func inOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
	/// Slow in, then past the end by an amount `back` sets, and back.
	static func overshoot(_ u: Double, back: Double) -> Double {
		let s = u * u * (3 - 2 * u), t = s - 1
		return 1 + (back + 1) * t * t * t + back * t * t
	}
	/// Down quickly, held, then released: a button press over one duration.
	static func press(_ u: Double) -> Double { u < 0.25 ? out(u / 0.25) : u < 0.75 ? 1 : 1 - inOut((u - 0.75) / 0.25) }
}

private extension CGPoint {
	static func + (a: CGPoint, b: CGVector) -> CGPoint { CGPoint(x: a.x + b.dx, y: a.y + b.dy) }
	static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
}

private extension CGVector {
	static func * (v: CGVector, k: Double) -> CGVector { CGVector(dx: v.dx * k, dy: v.dy * k) }
	static func + (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy) }
	var length: Double { hypot(dx, dy) }
	var unit: CGVector { length < 0.001 ? CGVector(dx: 1, dy: 0) : self * (1 / length) }
}

/// The real pointer in global Core Graphics points.
@MainActor
private func realPointer() -> CGPoint? {
	guard let primary = NSScreen.screens.first else { return nil }
	let location = NSEvent.mouseLocation
	return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
}

private func windowInfo(_ window: CGWindowID) -> (bounds: CGRect, onScreen: Bool, level: Int)? {
	guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
		let frame = info[kCGWindowBounds as String] as? NSDictionary,
		let bounds = CGRect(dictionaryRepresentation: frame)
	else { return nil }
	return (bounds, info[kCGWindowIsOnscreen as String] as? Bool ?? false, info[kCGWindowLayer as String] as? Int ?? 0)
}

// MARK: One agent's cursor

@MainActor
private final class Cursor {
	let agent: AgentIdentity
	/// The exact window of the latest request.
	var window: CGWindowID?
	private let wake: () -> Void
	private var overlays: [Overlay] = []
	/// The window the cursor is over, which it stays directly above so windows covering it cover the cursor too; nil
	/// keeps it above everything, as on its way out of and back into the real pointer.
	private var anchor: CGWindowID?

	private var position = CGPoint.zero
	private var scale = 1.0
	private var opacity = 0.0
	/// Rotation a phase sets, such as the peel, on top of the tilt.
	private var spin = 0.0
	/// Smoothed velocity in points per second, for stretch and tilt.
	private var velocity = CGVector.zero
	private var tilt = 0.0
	private var tag = CGPoint.zero
	private var tagVelocity = CGVector.zero
	private var last: CGPoint?
	private var pressStart: Double?
	private var holding = false
	/// Whether a newer input took over from the one running.
	private var generation = 0
	/// The running phase: it moves the cursor each frame and returns false once it ends.
	private var phase: ((Double, Double) -> Bool)?
	private var done: CheckedContinuation<Void, Never>?
	private var rest: Task<Void, Never>?

	init(_ agent: AgentIdentity, wake: @escaping () -> Void) {
		self.agent = agent
		self.wake = wake
	}

	var isVisible: Bool { !overlays.isEmpty }

	func show(_ feedback: Hooks.PointerFeedback) async {
		generation += 1
		let run = generation
		rest?.cancel()
		switch feedback {
		case let .click(point, kind, window):
			self.window = CGWindowID(exactly: window) ?? self.window
			guard await arrive(at: point, run: run) else { return }
			if holding {
				holding = false
			} else {
				pressStart = CACurrentMediaTime()
			}
			let count = switch kind {
			case .double: 2
			case .triple: 3
			default: 1
			}
			for index in 0..<count { ripple(at: point, dashed: kind == .right, delay: Double(index) * 0.12) }
			goHome(after: Tuning.idle)
		case let .hold(point, window):
			self.window = CGWindowID(exactly: window) ?? self.window
			guard await arrive(at: point, run: run) else { return }
			holding = true
			ripple(at: point, dashed: false, delay: 0)
			goHome(after: Tuning.idle + Tuning.longestHold)
		case let .scroll(point, direction, _, window):
			self.window = CGWindowID(exactly: window) ?? self.window
			guard await arrive(at: point, run: run) else { return }
			chevrons(at: point, direction: direction)
			goHome(after: Tuning.idle)
		case let .drag(from, to, seconds, window):
			self.window = CGWindowID(exactly: window) ?? self.window
			guard await arrive(at: from, run: run) else { return }
			drag(from: from, to: to, duration: seconds)
			goHome(after: Tuning.idle + seconds)
		case let .move(point, window):
			self.window = CGWindowID(exactly: window) ?? self.window
			guard await arrive(at: point, run: run) else { return }
			goHome(after: Tuning.idle)
		}
	}

	func discard() {
		rest?.cancel()
		finish()
		for overlay in overlays { overlay.close() }
		overlays = []
	}

	// MARK: Phases

	/// Runs a phase until it ends or a newer input takes over.
	private func run(_ step: @escaping (_ now: Double, _ dt: Double) -> Bool) async {
		finish()
		// Nothing steps a discarded cursor, so a phase would never end.
		guard !overlays.isEmpty else { return }
		wake()
		await withCheckedContinuation { continuation in
			done = continuation
			phase = step
		}
	}

	private func finish() {
		phase = nil
		let done = done
		self.done = nil
		done?.resume()
	}

	/// Brings the cursor to `point`: out of the real pointer when it isn't up, else from wherever it is now, even on
	/// its way home. False when a newer input took over.
	private func arrive(at point: CGPoint, run: Int) async -> Bool {
		var budget = Tuning.travelLong
		if overlays.isEmpty {
			overlays = NSScreen.screens.map { Overlay($0, agent: agent) }
			anchor = nil
			for overlay in overlays { overlay.show(above: nil) }
			let start = realPointer() ?? point
			position = start
			tag = start
			last = nil
			velocity = .zero
			await breakout(from: start, toward: point)
			guard run == generation else { return false }
			budget = Tuning.firstWait - Tuning.windup - Tuning.peel
		}
		if (point - position).length < 1 {
			// Already there, as when a held button is released: arrive at once so the input isn't delayed.
			finish()
			position = point
		} else {
			await travel(to: point, longest: budget)
		}
		guard run == generation else { return false }
		anchor(at: point)
		return true
	}

	/// A wind-up at the real pointer, with a halo dipping around it, then a peel away toward the first input.
	private func breakout(from origin: CGPoint, toward target: CGPoint) async {
		let direction = (target - origin).unit
		let side = CGVector(dx: -direction.dy, dy: direction.dx)
		opacity = 1
		halo(dip: true, length: Tuning.windup + Tuning.peel * 0.5)
		var start = CACurrentMediaTime()
		await run { [self] now, _ in
			let u = min((now - start) / Tuning.windup, 1)
			position = origin
			scale = 1 - Tuning.dip * Ease.out(u)
			return u < 1
		}
		start = CACurrentMediaTime()
		let dipped = 1 - Tuning.dip
		await run { [self] now, _ in
			let u = min((now - start) / Tuning.peel, 1)
			let out = Ease.out(u)
			position = origin + direction * (Tuning.peelDistance * out) + side * (Tuning.peelDistance * 0.6 * sin(.pi * u))
			spin = -0.5 * (1 - out)
			scale = dipped + (1 - dipped) * out
			return u < 1
		}
		spin = 0
		scale = 1
	}

	/// Peekaboo's path: a quadratic Bézier bent to one side, taking 205–400 ms by distance, with a slight overshoot.
	private func travel(to target: CGPoint, longest: Double) async {
		let from = position
		let delta = target - from
		let distance = max(delta.length, 1)
		let length = min(Tuning.travelShort + min(distance / 1600, 1) * (Tuning.travelLong - Tuning.travelShort), longest)
		let bend = min(distance * Tuning.bend, Tuning.bendMost)
		let control = CGPoint(x: (from.x + target.x) / 2 - delta.dy / distance * bend, y: (from.y + target.y) / 2 + delta.dx / distance * bend)
		let start = CACurrentMediaTime()
		await run { [self] now, _ in
			let u = min((now - start) / length, 1)
			let p = Ease.overshoot(u, back: Tuning.overshoot), q = 1 - p
			position = CGPoint(
				x: q * q * from.x + 2 * q * p * control.x + p * p * target.x,
				y: q * q * from.y + 2 * q * p * control.y + p * p * target.y)
			return u < 1
		}
	}

	/// Once the agent goes quiet, springs back to the live pointer, so it never waits for the hand to stop, then merges.
	private func goHome(after seconds: Double) {
		rest?.cancel()
		let run = generation
		rest = Task { [weak self] in
			try? await Task.sleep(for: .seconds(seconds))
			guard !Task.isCancelled, let self, run == self.generation else { return }
			await self.home(run: run)
		}
	}

	private func home(run: Int) async {
		holding = false
		anchor = nil
		for overlay in overlays { overlay.show(above: nil) }
		var springVelocity = velocity
		let k = Tuning.homeStiffness, c = 2 * Tuning.homeDamping * sqrt(k)
		await self.run { [self] _, dt in
			guard let pointer = realPointer() else { return false }
			let gap = pointer - position
			springVelocity = springVelocity + (gap * k + springVelocity * -c) * dt
			position = position + springVelocity * dt
			return !(gap.length < 4 && springVelocity.length < 120)
		}
		guard run == generation, let pointer = realPointer() else { return }
		ripple(at: pointer, dashed: false, delay: 0)
		halo(dip: false, length: Tuning.merge * 2)
		let start = CACurrentMediaTime()
		await self.run { [self] now, _ in
			let u = min((now - start) / Tuning.merge, 1)
			position = realPointer() ?? position
			scale = 1 - 0.5 * Ease.out(u)
			opacity = 1 - u
			return u < 1
		}
		guard run == generation else { return }
		scale = 1
		opacity = 0
		discard()
	}

	/// Anchors the cursor to the request's window when `point` is inside it, or keeps it above everything for input
	/// outside any one window, such as the Dock or the menu bar.
	private func anchor(at point: CGPoint) {
		anchor = window.flatMap { window in
			guard let info = windowInfo(window), info.onScreen, info.bounds.contains(point) else { return nil }
			return window
		}
		for overlay in overlays { overlay.show(above: anchor) }
	}

	// MARK: Frames

	func step(now: Double, dt: Double) {
		guard !overlays.isEmpty else { return }
		if let phase, !phase(now, dt) { finish() }
		if let anchor {
			// Directly above the anchor window, hidden while it is off screen.
			let info = windowInfo(anchor)
			for overlay in overlays {
				if let info, info.onScreen { overlay.order(above: anchor, level: info.level) } else { overlay.conceal() }
			}
		}
		let raw = last.map { (position - $0) * (1 / dt) } ?? .zero
		last = position
		let smoothing = 1 - exp(-dt * 30)
		velocity = velocity * (1 - smoothing) + raw * smoothing
		let tiltTarget = max(-1, min(1, velocity.dx / 1000 * Tuning.tiltGain / Tuning.tiltMost)) * Tuning.tiltMost * .pi / 180
		tilt += (tiltTarget - tilt) * (1 - exp(-dt * 12))
		// The tag trails on a spring, capped so it stays beside the cursor at travel speed.
		let anchorPoint = position + CGVector(dx: 14, dy: 24)
		let k = Tuning.tagStiffness, c = 2 * Tuning.tagDamping * sqrt(k)
		tagVelocity = tagVelocity + ((anchorPoint - tag) * k + tagVelocity * -c) * dt
		tag = tag + tagVelocity * dt
		let lag = tag - anchorPoint
		if lag.length > Tuning.tagLag { tag = anchorPoint + lag.unit * Tuning.tagLag }

		var press = 1.0
		if holding {
			press = Tuning.pressScale
		} else if let pressStart {
			let u = (now - pressStart) / Tuning.press
			if u >= 1 { self.pressStart = nil } else { press = 1 - (1 - Tuning.pressScale) * Ease.press(max(u, 0)) }
		}
		var transform = CGAffineTransform.identity
		let stretch = min(velocity.length / 1000 * Tuning.stretchGain, Tuning.stretchMost)
		if stretch > 0.001 {
			// Longer along the motion and thinner across it, keeping its area.
			let angle = atan2(velocity.dy, velocity.dx), k = 1 + stretch
			transform = transform.rotated(by: angle).scaledBy(x: k, y: 1 / k).rotated(by: -angle)
		}
		let size = scale * press
		transform = transform.rotated(by: tilt + spin).scaledBy(x: size, y: size)
		for overlay in overlays { overlay.draw(at: position, transform: transform, opacity: opacity, tag: tag) }
	}

	// MARK: Effects

	private func ripple(at point: CGPoint, dashed: Bool, delay: TimeInterval) {
		let color = agent.tint.color
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
			grow.toValue = Tuning.pop
			let vanish = CABasicAnimation(keyPath: "opacity")
			vanish.fromValue = 0.95
			vanish.toValue = 0
			let group = CAAnimationGroup()
			group.animations = [grow, vanish]
			group.duration = Tuning.ripple
			group.beginTime = CACurrentMediaTime() + delay
			group.timingFunction = CAMediaTimingFunction(name: .easeOut)
			overlay.expire(ring, after: Tuning.ripple + delay, animation: group)
		}
	}

	/// A ring around the real pointer, standing in for the dip and pop macOS won't let us draw on the pointer itself.
	private func halo(dip: Bool, length: TimeInterval) {
		guard let pointer = realPointer() else { return }
		for overlay in overlays {
			let ring = CAShapeLayer()
			ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
			ring.fillColor = nil
			ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
			ring.lineWidth = 1.5
			ring.shadowColor = .black
			ring.shadowOpacity = 0.4
			ring.shadowRadius = 2
			ring.shadowOffset = .zero
			ring.opacity = 0
			overlay.effect(ring, at: pointer + CGVector(dx: 5, dy: 8))
			let size = CAKeyframeAnimation(keyPath: "transform.scale")
			size.values = dip ? [1, 1 - Tuning.dip * 2, 1] : [0.6, 1.4]
			let fade = CAKeyframeAnimation(keyPath: "opacity")
			fade.values = dip ? [0, 0.8, 0] : [0.8, 0]
			let group = CAAnimationGroup()
			group.animations = [size, fade]
			group.duration = length
			overlay.expire(ring, after: length, animation: group)
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
		let color = agent.tint.color
		for overlay in overlays {
			let layer = CAShapeLayer()
			layer.path = glyph
			layer.fillColor = nil
			layer.strokeColor = color
			layer.lineWidth = 3
			layer.lineCap = .round
			layer.lineJoin = .round
			layer.shadowColor = color
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

	/// Holds the button down along a straight line, leaving a dotted trail; the input doesn't wait for it.
	private func drag(from: CGPoint, to: CGPoint, duration: TimeInterval) {
		let line = CGMutablePath()
		line.move(to: from)
		line.addLine(to: to)
		let color = agent.tint.color
		for overlay in overlays {
			let trail = CAShapeLayer()
			trail.path = line.copy(using: [overlay.transform])
			trail.fillColor = nil
			trail.strokeColor = color.copy(alpha: 0.85)
			trail.lineWidth = 3
			trail.lineCap = .round
			trail.lineDashPattern = [1, 7]
			trail.shadowColor = color
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
		}
		holding = true
		let start = CACurrentMediaTime()
		finish()
		phase = { [self] now, _ in
			let u = duration > 0 ? min((now - start) / duration, 1) : 1
			position = CGPoint(x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u)
			if u >= 1 { holding = false }
			return u < 1
		}
		wake()
	}
}

// MARK: Overlay

/// One click-through panel per display for one agent; each draws the same scene clipped to its screen.
@MainActor
private final class Overlay {
	private final class Panel: NSPanel {
		override var canBecomeKey: Bool { false }
		override var canBecomeMain: Bool { false }
	}

	/// Maps global Core Graphics points into this panel's top-left-origin layer space.
	let transform: CGAffineTransform
	private let panel: Panel
	private let root = CALayer()
	private let effects = CALayer()
	private let cursor = CALayer()
	private let tag = CALayer()

	init(_ screen: NSScreen, agent: AgentIdentity) {
		let primary = NSScreen.screens.first?.frame ?? screen.frame
		transform = CGAffineTransform(translationX: -screen.frame.minX, y: -(primary.maxY - screen.frame.maxY))
		panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
		root.addSublayer(tag)
		root.addSublayer(cursor)
		panel.contentView = view
		Self.drawArrow(cursor, color: agent.tint.color, scale: screen.backingScaleFactor)
		Self.drawTag(tag, name: agent.name, tint: agent.tint, scale: screen.backingScaleFactor)
	}

	/// The arrow's tip is the layer's anchor, so scaling and turning pivot at the hotspot.
	private static func drawArrow(_ cursor: CALayer, color: CGColor, scale: CGFloat) {
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
		shape.fillColor = color
		shape.strokeColor = .white
		shape.lineWidth = 1.5
		shape.lineJoin = .round
		shape.contentsScale = scale
		shape.shadowColor = color
		shape.shadowOpacity = 0.9
		shape.shadowRadius = 7
		shape.shadowOffset = .zero
		cursor.addSublayer(shape)
	}

	private static func drawTag(_ pill: CALayer, name: String, tint: AgentIdentity.Tint, scale: CGFloat) {
		let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
		let width = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 14
		pill.bounds = CGRect(x: 0, y: 0, width: width, height: 18)
		pill.anchorPoint = .zero
		pill.backgroundColor = tint.color
		pill.borderColor = tint.rim
		pill.borderWidth = 1
		pill.cornerRadius = 9
		pill.opacity = 0
		pill.shadowColor = .black
		pill.shadowOpacity = 0.25
		pill.shadowRadius = 3
		pill.shadowOffset = .zero
		let text = CATextLayer()
		text.string = name
		text.font = font
		text.fontSize = 11
		text.foregroundColor = .white
		text.alignmentMode = .center
		text.truncationMode = .end
		text.contentsScale = scale
		text.frame = pill.bounds.insetBy(dx: 7, dy: 2)
		pill.addSublayer(text)
	}

	/// Shows the panel directly above `window`, or above everything without one.
	func show(above window: CGWindowID?) {
		if let window {
			order(above: window, level: windowInfo(window)?.level ?? 0)
		} else {
			if panel.level != .screenSaver { panel.level = .screenSaver }
			panel.orderFrontRegardless()
		}
	}

	func order(above window: CGWindowID, level: Int) {
		if panel.level.rawValue != level { panel.level = NSWindow.Level(rawValue: level) }
		if !panel.isVisible || !isOrderedAbove(panel.windowNumber, window) {
			panel.order(.above, relativeTo: Int(window))
		}
	}

	func conceal() {
		if panel.isVisible { panel.orderOut(nil) }
	}

	func draw(at point: CGPoint, transform shape: CGAffineTransform, opacity: Double, tag at: CGPoint) {
		cursor.position = point.applying(transform)
		cursor.setAffineTransform(shape)
		cursor.opacity = Float(opacity)
		tag.position = at.applying(transform)
		tag.opacity = Float(opacity)
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

	func close() {
		panel.orderOut(nil)
		panel.close()
	}
}
