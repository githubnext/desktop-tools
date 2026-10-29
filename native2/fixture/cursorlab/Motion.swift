import AppKit
import QuartzCore

// The cursor lab's animation engine: agent cursors that break out of the real pointer, travel, click and merge back.
// Everything is driven per frame from one clock, so slow motion scales springs and effects alike. Points are global
// Core Graphics coordinates, as in DesktopTools/Cursor.swift: top-left origin on the primary display.

// MARK: Tuning

struct Knob {
	let key: String, label: String, section: String
	let range: ClosedRange<Double>
	let value: Double
	/// Shown after the value; "ms" knobs are read in seconds through `Tuning.seconds`.
	let unit: String
}

enum Defaults {
	static let knobs: [Knob] = [
		Knob(key: "windup", label: "Wind-up", section: "Timing", range: 0...200, value: 60, unit: "ms"),
		Knob(key: "breakout", label: "Breakout", section: "Timing", range: 0...500, value: 180, unit: "ms"),
		Knob(key: "travelMin", label: "Travel, short", section: "Timing", range: 80...600, value: 250, unit: "ms"),
		Knob(key: "travelMax", label: "Travel, 1600 pt", section: "Timing", range: 80...800, value: 400, unit: "ms"),
		Knob(key: "stagger", label: "Stagger", section: "Timing", range: 0...400, value: 120, unit: "ms"),
		Knob(key: "outlineDelay", label: "Outline delay", section: "Timing", range: 0...600, value: 0, unit: "ms"),
		Knob(key: "outline", label: "Outline in", section: "Timing", range: 0...600, value: 160, unit: "ms"),
		Knob(key: "press", label: "Press", section: "Timing", range: 60...400, value: 160, unit: "ms"),
		Knob(key: "ripple", label: "Ripple", section: "Timing", range: 150...1000, value: 400, unit: "ms"),
		Knob(key: "idle", label: "Pause before home", section: "Timing", range: 0...4000, value: 900, unit: "ms"),
		Knob(key: "merge", label: "Merge", section: "Timing", range: 60...600, value: 180, unit: "ms"),
		Knob(key: "fade", label: "Fade", section: "Timing", range: 100...1500, value: 400, unit: "ms"),

		Knob(key: "bend", label: "Arc bend", section: "Motion", range: 0...0.3, value: 0.09, unit: "× dist"),
		Knob(key: "bendMax", label: "Arc bend, max", section: "Motion", range: 0...150, value: 54, unit: "pt"),
		Knob(key: "overshoot", label: "Travel overshoot", section: "Motion", range: 0...3, value: 0.6, unit: ""),
		Knob(key: "stiffness", label: "Return stiffness", section: "Motion", range: 20...600, value: 170, unit: ""),
		Knob(key: "damping", label: "Return damping", section: "Motion", range: 0.2...1.5, value: 0.75, unit: "ratio"),
		Knob(key: "tagStiffness", label: "Tag stiffness", section: "Motion", range: 20...2000, value: 600, unit: ""),
		Knob(key: "tagDamping", label: "Tag damping", section: "Motion", range: 0.2...1.5, value: 0.7, unit: "ratio"),
		Knob(key: "tagLag", label: "Tag lag, max", section: "Motion", range: 0...120, value: 18, unit: "pt"),
		Knob(key: "budDistance", label: "Breakout distance", section: "Motion", range: 0...80, value: 24, unit: "pt"),

		Knob(key: "dip", label: "Anticipation dip", section: "Shape", range: 0...0.4, value: 0.12, unit: ""),
		Knob(key: "budStart", label: "Bud start size", section: "Shape", range: 0.1...1, value: 0.5, unit: "×"),
		Knob(key: "stretchGain", label: "Stretch per 1000 pt/s", section: "Shape", range: 0...0.6, value: 0.12, unit: ""),
		Knob(key: "stretchMax", label: "Stretch, max", section: "Shape", range: 0...0.8, value: 0.35, unit: ""),
		Knob(key: "tiltGain", label: "Tilt per 1000 pt/s", section: "Shape", range: 0...20, value: 6, unit: "°"),
		Knob(key: "tiltMax", label: "Tilt, max", section: "Shape", range: 0...40, value: 14, unit: "°"),
		Knob(key: "pressScale", label: "Press squeeze", section: "Shape", range: 0.5...1, value: 0.82, unit: "×"),
		Knob(key: "pop", label: "Click and merge pop", section: "Shape", range: 1...2.5, value: 1.6, unit: "×"),
		Knob(key: "size", label: "Cursor size", section: "Shape", range: 0.6...2, value: 1, unit: "×"),

		Knob(key: "actions", label: "Clicks per agent", section: "Scenario", range: 1...8, value: 3, unit: ""),
		Knob(key: "think", label: "Gap between clicks", section: "Scenario", range: 100...3000, value: 700, unit: "ms"),
	]

	static let flags: [(key: String, label: String, value: Bool)] = [
		("anticipation", "Anticipation", true),
		("squash", "Squash and stretch", true),
		("arcs", "Arcs", true),
		("followThrough", "Follow-through", true),
		("tilt", "Secondary tilt", true),
		("exaggerate", "Exaggerated click and merge", true),
		("staged", "Staged one at a time", true),
		("nameTag", "Name tag", true),
		("halo", "Halo at your pointer", true),
	]

	static let breakouts = ["Bud", "Peel", "Appear at window"]
	static let endings = ["Merge back", "Fade at window"]
	static let speeds: [(label: String, value: Double)] = [("1×", 1), ("½×", 0.5), ("¼×", 0.25)]
}

@MainActor
final class Tuning {
	var values = Dictionary(uniqueKeysWithValues: Defaults.knobs.map { ($0.key, $0.value) })
	var flags = Dictionary(uniqueKeysWithValues: Defaults.flags.map { ($0.key, $0.value) })
	var breakout = 0
	var ending = 0
	var agents = 2
	var speed = 0
	var loop = true

	subscript(key: String) -> Double { values[key] ?? 0 }
	func on(_ key: String) -> Bool { flags[key] ?? false }
	func seconds(_ key: String) -> Double { self[key] / 1000 }

	/// The longest any agent's first input waits for its cursor, from the request to arrival, as Hooks.pointerLimit counts it.
	var worstFirstWait: Double {
		let windup = on("anticipation") && breakout != 2 ? seconds("windup") : 0
		let travel = breakout == 2 ? 0 : seconds("travelMax")
		let stagger = on("staged") ? seconds("stagger") * Double(agents - 1) : 0
		return windup + seconds("breakout") + travel + stagger
	}

	var json: [String: Any] {
		[
			"values": values, "flags": flags, "breakout": Defaults.breakouts[breakout], "ending": Defaults.endings[ending],
			"agents": agents, "speed": Defaults.speeds[speed].value, "loop": loop,
		]
	}

	func load(_ json: [String: Any]) {
		for (key, value) in json["values"] as? [String: Double] ?? [:] where values[key] != nil { values[key] = value }
		for (key, value) in json["flags"] as? [String: Bool] ?? [:] where flags[key] != nil { flags[key] = value }
		breakout = (json["breakout"] as? String).flatMap(Defaults.breakouts.firstIndex) ?? breakout
		ending = (json["ending"] as? String).flatMap(Defaults.endings.firstIndex) ?? ending
		agents = json["agents"] as? Int ?? agents
		speed = (json["speed"] as? Double).flatMap { s in Defaults.speeds.firstIndex { $0.value == s } } ?? speed
		loop = json["loop"] as? Bool ?? loop
	}
}

// MARK: Easing

enum Ease {
	static func out(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
	static func inOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
	/// Slow in, then past the end by an amount `back` sets (1.70158 is the classic ten percent), and back.
	static func overshoot(_ u: Double, back: Double) -> Double {
		guard back > 0 else { return inOut(u) }
		let s = u * u * (3 - 2 * u), t = s - 1
		return 1 + (back + 1) * t * t * t + back * t * t
	}
	/// Up quickly, held, then released: a button press over one duration.
	static func press(_ u: Double) -> Double { u < 0.25 ? out(u / 0.25) : u < 0.75 ? 1 : 1 - inOut((u - 0.75) / 0.25) }
}

extension CGPoint {
	static func + (a: CGPoint, b: CGVector) -> CGPoint { CGPoint(x: a.x + b.dx, y: a.y + b.dy) }
	static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
}

extension CGVector {
	static func * (v: CGVector, k: Double) -> CGVector { CGVector(dx: v.dx * k, dy: v.dy * k) }
	static func + (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy) }
	var length: Double { hypot(dx, dy) }
	var unit: CGVector { length < 0.001 ? CGVector(dx: 1, dy: 0) : self * (1 / length) }
}

/// The real pointer in global Core Graphics points.
@MainActor
func pointer() -> CGPoint {
	let location = NSEvent.mouseLocation
	return CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
}

/// Converts between Cocoa screen frames (bottom-left origin) and global Core Graphics ones; the flip is its own inverse.
@MainActor
func flipped(_ frame: CGRect) -> CGRect {
	let primary = NSScreen.screens.first?.frame.maxY ?? 0
	return CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
}

// MARK: Overlay

/// One click-through panel per display, as the real cursor has. Unlike it, the lab's overlay shows in captures and
/// screen recordings, so motion can be recorded and stepped through.
@MainActor
final class Overlay {
	private let panel: NSPanel
	let root = CALayer()
	/// Maps global Core Graphics points into this panel's top-left-origin layer space.
	let transform: CGAffineTransform
	let scale: CGFloat

	init(_ screen: NSScreen) {
		let primary = NSScreen.screens.first?.frame ?? screen.frame
		transform = CGAffineTransform(translationX: -screen.frame.minX, y: -(primary.maxY - screen.frame.maxY))
		scale = screen.backingScaleFactor
		panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		panel.level = .screenSaver
		panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
		panel.ignoresMouseEvents = true
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.animationBehavior = .none
		panel.setFrame(screen.frame, display: false)
		let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
		view.wantsLayer = true
		root.isGeometryFlipped = true
		root.frame = view.bounds
		view.layer?.addSublayer(root)
		panel.contentView = view
		panel.orderFrontRegardless()
	}

	func close() {
		panel.orderOut(nil)
		panel.close()
	}
}

// MARK: Sprites and effects

/// One agent's cursor and name tag, drawn on every display.
@MainActor
final class Sprite {
	let name: String
	let color: CGColor
	var position = CGPoint.zero
	var scale = 1.0
	var opacity = 0.0
	/// Rotation a phase sets, such as a peel, on top of the tilt.
	var spin = 0.0
	/// Extra stretch a phase sets along `pull`, such as a bud pulling away.
	var pull: (CGVector, Double)?
	var pressStart: Double?
	/// Smoothed velocity in points per clock second, for stretch and tilt.
	var velocity = CGVector.zero
	/// The return spring's own velocity.
	var springVelocity = CGVector.zero
	var tilt = 0.0
	var tag = CGPoint.zero
	var tagVelocity = CGVector.zero
	private var last: CGPoint?
	private var nodes: [CALayer] = []
	private var tags: [CALayer] = []
	/// The running phase: it moves the sprite each frame and returns false once it ends.
	private var phase: ((Double, Double) -> Bool)?
	private var done: CheckedContinuation<Void, Never>?

	init(name: String, color: CGColor, overlays: [Overlay]) {
		self.name = name
		self.color = color
		for overlay in overlays {
			let node = Self.arrow(color: color, scale: overlay.scale)
			let tag = Self.tag(name, color: color, scale: overlay.scale)
			overlay.root.addSublayer(tag)
			overlay.root.addSublayer(node)
			nodes.append(node)
			tags.append(tag)
		}
	}

	/// Runs a phase until it ends, or until the engine cancels the run.
	func run(_ step: @escaping (_ now: Double, _ dt: Double) -> Bool) async {
		finish()
		await withCheckedContinuation { continuation in
			done = continuation
			phase = step
		}
	}

	func finish() {
		phase = nil
		let done = done
		self.done = nil
		done?.resume()
	}

	func remove() {
		finish()
		for layer in nodes + tags { layer.removeFromSuperlayer() }
	}

	func step(now: Double, dt: Double, tuning: Tuning, overlays: [Overlay]) {
		if let phase, !phase(now, dt) { finish() }
		guard dt > 0 else { return }
		let raw = last.map { (position - $0) * (1 / dt) } ?? .zero
		last = position
		velocity = velocity * exp(-dt * 30) + raw * (1 - exp(-dt * 30))
		let tiltTarget = tuning.on("tilt")
			? max(-1, min(1, velocity.dx / 1000 * tuning["tiltGain"] / max(tuning["tiltMax"], 0.001))) * tuning["tiltMax"] * .pi / 180
			: 0
		tilt += (tiltTarget - tilt) * (1 - exp(-dt * 12))
		let anchor = position + CGVector(dx: 14, dy: 24) * tuning["size"]
		if tuning.on("followThrough") {
			let k = tuning["tagStiffness"], c = 2 * tuning["tagDamping"] * sqrt(k)
			tagVelocity = tagVelocity + ((anchor - tag) * k + tagVelocity * -c) * dt
			tag = tag + tagVelocity * dt
			// A spring alone trails by hundreds of points at travel speed; the lag is capped instead.
			let lag = tag - anchor, most = tuning["tagLag"]
			if lag.length > most { tag = anchor + lag.unit * most }
		} else {
			tag = anchor
		}

		var press = 1.0
		if let pressStart {
			let u = (now - pressStart) / tuning.seconds("press")
			if u >= 1 { self.pressStart = nil } else { press = 1 - (1 - tuning["pressScale"]) * Ease.press(max(u, 0)) }
		}
		var transform = CGAffineTransform.identity
		if tuning.on("squash") {
			var stretch = min(velocity.length / 1000 * tuning["stretchGain"], tuning["stretchMax"])
			var direction = velocity
			if let (pullDirection, amount) = pull {
				stretch += amount
				direction = pullDirection
			}
			if stretch > 0.001 {
				let angle = atan2(direction.dy, direction.dx), k = 1 + stretch
				transform = transform.rotated(by: angle).scaledBy(x: k, y: 1 / k).rotated(by: -angle)
			}
		}
		let size = scale * press * tuning["size"]
		transform = transform.rotated(by: tilt + spin).scaledBy(x: size, y: size)
		for (index, overlay) in overlays.enumerated() where index < nodes.count {
			nodes[index].position = position.applying(overlay.transform)
			nodes[index].setAffineTransform(transform)
			nodes[index].opacity = Float(opacity)
			tags[index].position = tag.applying(overlay.transform)
			tags[index].opacity = tuning.on("nameTag") ? Float(opacity) : 0
		}
	}

	/// The same arrow the real cursor draws, with its tip at the layer's anchor so scaling and turning pivot there.
	private static func arrow(color: CGColor, scale: CGFloat) -> CALayer {
		let path = CGMutablePath()
		let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 17.5), (4.2, 13.6), (7, 19.8), (9.8, 18.6), (7, 12.5), (12.6, 12.5)]
		path.addLines(between: points.map { CGPoint(x: $0.0 * 1.25, y: $0.1 * 1.25) })
		path.closeSubpath()
		let node = CALayer()
		node.bounds = CGRect(x: 0, y: 0, width: 18, height: 26)
		node.anchorPoint = .zero
		node.opacity = 0
		let shape = CAShapeLayer()
		shape.path = path
		shape.fillColor = color
		shape.strokeColor = .white
		shape.lineWidth = 1.5
		shape.lineJoin = .round
		shape.contentsScale = scale
		shape.shadowColor = color
		shape.shadowOpacity = 0.9
		shape.shadowRadius = 7
		shape.shadowOffset = .zero
		node.addSublayer(shape)
		return node
	}

	private static func tag(_ name: String, color: CGColor, scale: CGFloat) -> CALayer {
		let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
		let width = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 14
		let pill = CALayer()
		pill.bounds = CGRect(x: 0, y: 0, width: width, height: 18)
		pill.anchorPoint = .zero
		pill.backgroundColor = color
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
		text.contentsScale = scale
		text.frame = pill.bounds.insetBy(dx: 7, dy: 2)
		pill.addSublayer(text)
		return pill
	}
}

/// A one-shot drawing, such as a ripple, on every display; `step` returns false once it ends.
@MainActor
final class Effect {
	let layers: [CALayer]
	let step: ([CALayer], [Overlay]) -> Bool

	init(_ overlays: [Overlay], make: (Overlay) -> CALayer, step: @escaping ([CALayer], [Overlay]) -> Bool) {
		layers = overlays.map { overlay in
			let layer = make(overlay)
			layer.opacity = 0
			overlay.root.insertSublayer(layer, at: 0)
			return layer
		}
		self.step = step
	}
}

// MARK: Engine

/// A scene window an agent works in.
struct Stage {
	let window: NSWindow
	var frame: CGRect { MainActor.assumeIsolated { flipped(window.frame) } }
	var name: String { MainActor.assumeIsolated { window.title } }
}

@MainActor
final class Engine: NSObject {
	let tuning: Tuning
	var stages: [Stage] = []
	/// Called with each input's wait for its cursor, in seconds, by agent and click.
	var waited: ((String, Int, Double) -> Void)?
	var running: ((Bool) -> Void)?
	fileprivate var overlays: [Overlay] = []
	private var link: CADisplayLink?
	private var last: CFTimeInterval?
	/// Clock seconds, which run slower than real ones in slow motion.
	private(set) var now = 0.0
	private var sleepers: [(at: Double, resume: CheckedContinuation<Void, Never>)] = []
	private var sprites: [Sprite] = []
	private var effects: [Effect] = []
	private var generation = 0

	static let agents: [(name: String, color: CGColor)] = [
		("Claude", NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor),
		("Codex", NSColor(srgbRed: 0.30, green: 0.55, blue: 0.98, alpha: 1).cgColor),
		("Gemini", NSColor(srgbRed: 0.55, green: 0.40, blue: 0.95, alpha: 1).cgColor),
	]

	init(tuning: Tuning) {
		self.tuning = tuning
		super.init()
		rebuild()
		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { _ in MainActor.assumeIsolated { self.stop(); self.rebuild() } }
	}

	private func rebuild() {
		for overlay in overlays { overlay.close() }
		overlays = NSScreen.screens.map(Overlay.init)
		link?.invalidate()
		link = NSScreen.screens.first?.displayLink(target: self, selector: #selector(frame(_:)))
		link?.add(to: .main, forMode: .common)
		link?.isPaused = true
	}

	// MARK: Clock

	@objc private func frame(_ link: CADisplayLink) {
		let real = last.map { link.timestamp - $0 } ?? 1.0 / 60
		last = link.timestamp
		let dt = min(real, 1.0 / 30) * Defaults.speeds[tuning.speed].value
		now += dt
		let due = sleepers.filter { $0.at <= now }
		sleepers.removeAll { $0.at <= now }
		for sleeper in due { sleeper.resume.resume() }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for sprite in sprites { sprite.step(now: now, dt: dt, tuning: tuning, overlays: overlays) }
		effects.removeAll { effect in
			if effect.step(effect.layers, overlays) { return false }
			for layer in effect.layers { layer.removeFromSuperlayer() }
			return true
		}
		CATransaction.commit()
		// A clock left running burns CPU with nothing moving.
		if sleepers.isEmpty, sprites.isEmpty, effects.isEmpty {
			link.isPaused = true
			last = nil
		}
	}

	private func wake() {
		link?.isPaused = false
	}

	func sleep(_ seconds: Double) async {
		guard seconds > 0 else { return }
		wake()
		await withCheckedContinuation { sleepers.append((now + seconds, $0)) }
	}

	// MARK: Runs

	/// Starts every agent from the real pointer, ending any run in progress.
	func send() {
		stop()
		let run = generation
		running?(true)
		Task {
			// Plain tasks, not a task group: a group of main-actor children crashed the optimized build.
			let agents = (0..<tuning.agents).map { index in Task { await self.perform(agent: index, run: run) } }
			for agent in agents { await agent.value }
			guard run == generation else { return }
			if tuning.loop {
				await sleep(1.2)
				if run == generation { send() }
			} else {
				running?(false)
			}
		}
	}

	func stop() {
		generation += 1
		let pending = sleepers
		sleepers = []
		for sleeper in pending { sleeper.resume.resume() }
		for sprite in sprites { sprite.remove() }
		sprites = []
		for effect in effects { for layer in effect.layers { layer.removeFromSuperlayer() } }
		effects = []
		running?(false)
	}

	private func perform(agent index: Int, run: Int) async {
		guard !stages.isEmpty else { return }
		let requested = now
		let (name, color) = Self.agents[index % Self.agents.count]
		let stage = stages[index % stages.count]
		let sprite = Sprite(name: name, color: color, overlays: overlays)
		sprites.append(sprite)
		wake()
		defer {
			sprite.remove()
			sprites.removeAll { $0 === sprite }
		}
		if tuning.on("staged") { await sleep(tuning.seconds("stagger") * Double(index)) }
		guard run == generation else { return }
		let outline = Outline(engine: self, stage: stage, label: "\(name) is using \(stage.name)", color: color)
		Task {
			await sleep(tuning.seconds("outlineDelay"))
			if run == generation { outline.show() }
		}
		let clicks = Int(tuning["actions"].rounded())
		for click in 0..<clicks {
			let target = Self.spot(in: stage.frame)
			let start = click == 0 ? requested : now
			if click == 0 { await breakout(sprite, toward: target) }
			if click > 0 || tuning.breakout != 2 { await travel(sprite, to: target) }
			guard run == generation else { return }
			waited?(name, click, now - start)
			press(sprite, at: target)
			if click < clicks - 1 { await sleep(tuning.seconds("think")) }
			guard run == generation else { return }
		}
		await sleep(tuning.seconds("idle"))
		guard run == generation else { return }
		outline.hide()
		if tuning.ending == 0 { await home(sprite) } else { await fade(sprite) }
	}

	/// A point an agent might click, away from the window's edges and titlebar.
	private static func spot(in frame: CGRect) -> CGPoint {
		let inner = CGRect(x: frame.minX + 40, y: frame.minY + 60, width: max(frame.width - 80, 1), height: max(frame.height - 100, 1))
		return CGPoint(x: .random(in: inner.minX...inner.maxX), y: .random(in: inner.minY...inner.maxY))
	}

	// MARK: Phases

	/// Leaves the real pointer for `target`: a wind-up, then a bud or a peel. Appearing at the window skips both.
	private func breakout(_ sprite: Sprite, toward target: CGPoint) async {
		let length = tuning.seconds("breakout")
		if tuning.breakout == 2 {
			sprite.position = target
			let start = now
			await sprite.run { now, _ in
				let u = length > 0 ? min((now - start) / length, 1) : 1
				sprite.scale = max(Ease.overshoot(u, back: self.tuning.on("followThrough") ? 1.7 : 0), 0)
				sprite.opacity = min(u * 3, 1)
				return u < 1
			}
			return
		}
		let origin = pointer()
		let direction = (target - origin).unit
		let peel = tuning.breakout == 1
		sprite.position = origin
		sprite.opacity = peel ? 1 : 0
		var dipped = 1.0
		if tuning.on("anticipation"), tuning["windup"] > 0 {
			let length = tuning.seconds("windup"), dip = tuning["dip"], start = now
			if tuning.on("halo") { halo(dip: true, length: length + tuning.seconds("breakout") * 0.5) }
			await sprite.run { now, _ in
				let u = min((now - start) / length, 1)
				sprite.position = origin
				sprite.scale = 1 - dip * Ease.out(u)
				return u < 1
			}
			dipped = 1 - dip
		}
		let distance = tuning["budDistance"], budStart = tuning["budStart"], squash = tuning.on("squash")
		let side = CGVector(dx: -direction.dy, dy: direction.dx)
		let start = now
		await sprite.run { now, _ in
			let u = length > 0 ? min((now - start) / length, 1) : 1
			let out = Ease.out(u)
			if peel {
				sprite.position = origin + direction * (distance * out) + side * (distance * 0.6 * sin(.pi * u))
				sprite.spin = -0.5 * (1 - out)
				sprite.scale = dipped + (1 - dipped) * out
			} else {
				sprite.position = origin + direction * (distance * out)
				sprite.scale = budStart + (1 - budStart) * Ease.overshoot(u, back: self.tuning.on("followThrough") ? 1.7 : 0)
				sprite.opacity = min(u * 3, 1)
				sprite.pull = squash ? (direction, 0.3 * sin(.pi * u)) : nil
			}
			return u < 1
		}
		sprite.spin = 0
		sprite.pull = nil
		sprite.scale = 1
		sprite.opacity = 1
	}

	/// Peekaboo's path: a quadratic Bézier bent to one side, taking longer the farther it goes.
	private func travel(_ sprite: Sprite, to target: CGPoint) async {
		let from = sprite.position
		let delta = target - from
		let distance = max(delta.length, 1)
		let short = tuning.seconds("travelMin"), long = tuning.seconds("travelMax")
		let length = short + min(distance / 1600, 1) * (long - short)
		let bend = tuning.on("arcs") ? min(distance * tuning["bend"], tuning["bendMax"]) : 0
		let control = CGPoint(x: (from.x + target.x) / 2 - delta.dy / distance * bend, y: (from.y + target.y) / 2 + delta.dx / distance * bend)
		let back = tuning.on("followThrough") ? tuning["overshoot"] : 0
		let start = now
		await sprite.run { now, _ in
			let u = length > 0 ? min((now - start) / length, 1) : 1
			let p = Ease.overshoot(u, back: back), q = 1 - p
			sprite.position = CGPoint(
				x: q * q * from.x + 2 * q * p * control.x + p * p * target.x,
				y: q * q * from.y + 2 * q * p * control.y + p * p * target.y)
			return u < 1
		}
	}

	private func press(_ sprite: Sprite, at point: CGPoint) {
		sprite.pressStart = now
		ripple(at: { point }, color: sprite.color, pop: tuning.on("exaggerate") ? tuning["pop"] : 1.25, length: tuning.seconds("ripple"))
	}

	/// Springs back to the live pointer, so it never waits for the hand to stop, then merges into it.
	private func home(_ sprite: Sprite) async {
		let k = tuning["stiffness"]
		let zeta = tuning.on("followThrough") ? tuning["damping"] : max(tuning["damping"], 1)
		let c = 2 * zeta * sqrt(k)
		sprite.springVelocity = sprite.velocity
		await sprite.run { _, dt in
			let gap = pointer() - sprite.position
			sprite.springVelocity = sprite.springVelocity + (gap * k + sprite.springVelocity * -c) * dt
			sprite.position = sprite.position + sprite.springVelocity * dt
			return !(gap.length < 4 && sprite.springVelocity.length < 120)
		}
		if tuning.on("exaggerate") {
			ripple(at: { pointer() }, color: sprite.color, pop: tuning["pop"], length: tuning.seconds("merge") * 2)
		}
		if tuning.on("halo") { halo(dip: false, length: tuning.seconds("merge") * 2) }
		let length = tuning.seconds("merge"), start = now
		await sprite.run { now, _ in
			let u = min((now - start) / length, 1)
			sprite.position = pointer()
			sprite.scale = 1 - 0.5 * Ease.out(u)
			sprite.opacity = 1 - u
			return u < 1
		}
	}

	private func fade(_ sprite: Sprite) async {
		let length = tuning.seconds("fade"), start = now
		await sprite.run { now, _ in
			let u = min((now - start) / length, 1)
			sprite.opacity = 1 - Ease.inOut(u)
			return u < 1
		}
	}

	// MARK: Effects

	fileprivate func add(_ effect: Effect) {
		effects.append(effect)
		wake()
	}

	private func ripple(at center: @escaping () -> CGPoint, color: CGColor, pop: Double, length: Double) {
		let start = now
		add(Effect(overlays, make: { _ in
			let ring = CAShapeLayer()
			ring.path = CGPath(ellipseIn: CGRect(x: -18, y: -18, width: 36, height: 36), transform: nil)
			ring.fillColor = color.copy(alpha: 0.18)
			ring.strokeColor = color
			ring.lineWidth = 2.5
			return ring
		}, step: { [unowned self] layers, overlays in
			Self.place(layers, u: (self.now - start) / length, center: center(), overlays: overlays) { layer, u in
				let s = 0.35 + (pop - 0.35) * Ease.out(u)
				layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
				layer.opacity = Float(0.95 * (1 - u))
			}
		}))
	}

	/// A ring around the real pointer, standing in for the dip and pop macOS won't let us draw on the pointer itself.
	private func halo(dip: Bool, length: Double) {
		let start = now, amount = tuning["dip"]
		let color = NSColor.white.withAlphaComponent(0.9).cgColor
		add(Effect(overlays, make: { _ in
			let ring = CAShapeLayer()
			ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
			ring.fillColor = nil
			ring.strokeColor = color
			ring.lineWidth = 1.5
			ring.shadowColor = .black
			ring.shadowOpacity = 0.4
			ring.shadowRadius = 2
			ring.shadowOffset = .zero
			return ring
		}, step: { [unowned self] layers, overlays in
			Self.place(layers, u: (self.now - start) / length, center: pointer() + CGVector(dx: 5, dy: 8), overlays: overlays) { layer, u in
				let s = dip ? 1 - amount * 2 * sin(.pi * u) : 0.6 + 0.8 * Ease.out(u)
				layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
				layer.opacity = Float(dip ? 0.8 * sin(.pi * u) : 0.8 * (1 - u))
			}
		}))
	}

	/// Positions an effect's layers at `center` and updates them; false once the effect has ended.
	private static func place(
		_ layers: [CALayer], u: Double, center: CGPoint, overlays: [Overlay], update: (CALayer, Double) -> Void
	) -> Bool {
		guard u < 1 else { return false }
		for (index, overlay) in overlays.enumerated() where index < layers.count {
			layers[index].position = center.applying(overlay.transform)
			update(layers[index], max(u, 0))
		}
		return true
	}

	// MARK: Outline

	/// The window outline and its label, drawn in on `show` and faded on `hide`, following the window as it moves.
	@MainActor
	final class Outline {
		private unowned let engine: Engine
		private let stage: Stage
		private let label: String
		private let color: CGColor
		private var shown: Double?
		private var hidden: Double?

		init(engine: Engine, stage: Stage, label: String, color: CGColor) {
			self.engine = engine
			self.stage = stage
			self.label = label
			self.color = color
		}

		func show() {
			shown = engine.now
			let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
			let width = ceil((label as NSString).size(withAttributes: [.font: font]).width) + 16
			engine.add(Effect(engine.overlays, make: { overlay in
				let group = CALayer()
				let line = CAShapeLayer()
				line.fillColor = nil
				line.strokeColor = color
				line.lineWidth = 3
				line.shadowColor = color
				line.shadowOpacity = 0.7
				line.shadowRadius = 6
				line.shadowOffset = .zero
				group.addSublayer(line)
				let pill = CALayer()
				pill.bounds = CGRect(x: 0, y: 0, width: width, height: 18)
				pill.backgroundColor = color
				pill.cornerRadius = 9
				let text = CATextLayer()
				text.string = label
				text.font = font
				text.fontSize = 11
				text.foregroundColor = .white
				text.alignmentMode = .center
				text.contentsScale = overlay.scale
				text.frame = pill.bounds.insetBy(dx: 8, dy: 2)
				pill.addSublayer(text)
				group.addSublayer(pill)
				return group
			}, step: { [unowned self] layers, overlays in
				guard let shown else { return false }
				let tuning = engine.tuning
				let entry = tuning.seconds("outline")
				let u = entry > 0 ? min((engine.now - shown) / entry, 1) : 1
				var opacity = Ease.out(u)
				if let hidden {
					let v = (engine.now - hidden) / tuning.seconds("fade")
					if v >= 1 { return false }
					opacity *= 1 - Ease.inOut(max(v, 0))
				}
				let frame = stage.frame
				for (index, overlay) in overlays.enumerated() where index < layers.count {
					let group = layers[index]
					group.opacity = Float(opacity)
					guard let line = group.sublayers?.first as? CAShapeLayer, let pill = group.sublayers?.last else { continue }
					let edge = frame.insetBy(dx: -2, dy: -2).applying(overlay.transform)
					line.path = CGPath(roundedRect: edge, cornerWidth: 14, cornerHeight: 14, transform: nil)
					line.strokeEnd = Ease.inOut(u)
					pill.position = CGPoint(x: edge.midX, y: edge.maxY)
					pill.opacity = Float(Ease.out(u))
				}
				return true
			}))
		}

		func hide() {
			if shown != nil, hidden == nil { hidden = engine.now }
		}
	}
}
