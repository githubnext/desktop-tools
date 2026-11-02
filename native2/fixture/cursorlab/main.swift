import AppKit

// The cursor lab: a playground for the agent cursor's motion. It opens three scene windows for agents to work in and a
// Cursor Lab window of switches and sliders, saves every change to ~/.local/state/desktop-tools2/cursor-lab.json, and
// shows how long each input waits for its cursor against Hooks.pointerLimit. Build and run it with
// `native2/fixture/cursorlab/run.sh`.

@MainActor
final class Lab: NSObject, NSApplicationDelegate {
	let tuning = Tuning()
	lazy var engine = Engine(tuning: tuning)
	private var scenes: [NSWindow] = []
	private var panel: NSWindow!
	private var controls: [() -> Void] = []
	private let budget = NSTextField(labelWithString: "")
	private let waits = NSTextField(wrappingLabelWithString: "Send agents to measure.")
	private var measured: [String: [Double]] = [:]
	private var sendButton: NSButton!
	private var save: Task<Void, Never>?

	static let limit = 0.6
	static let file = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".local/state/desktop-tools2/cursor-lab.json")

	func applicationDidFinishLaunching(_: Notification) {
		if let data = try? Data(contentsOf: Self.file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			tuning.load(json)
		}
		scenes = Scenes.make()
		engine.stages = scenes.map(Stage.init)
		engine.waited = { [weak self] name, click, seconds in self?.record(name, click, seconds) }
		engine.running = { [weak self] running in self?.sendButton.title = running ? "Stop" : "Send agents" }
		panel = makePanel()
		for window in scenes { window.orderFront(nil) }
		panel.makeKeyAndOrderFront(nil)
		NSApp.activate()
		refresh()
		if CommandLine.arguments.contains("--send") { send() }
	}

	func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

	// MARK: Readouts

	private func record(_ name: String, _ click: Int, _ seconds: Double) {
		if click == 0 { measured[name] = [] }
		measured[name, default: []].append(seconds)
		let lines = Engine.agents.map(\.name).compactMap { name -> String? in
			guard let waits = measured[name], let first = waits.first else { return nil }
			let later = waits.dropFirst().max().map { String(format: ", later up to %.0f ms", $0 * 1000) } ?? ""
			return String(format: "%@: first %.0f ms%@%@", name, first * 1000, later, first > Self.limit + 0.001 ? " ⚠︎" : "")
		}
		waits.stringValue = lines.joined(separator: "\n")
	}

	private func refresh() {
		let worst = tuning.worstFirstWait
		budget.stringValue = String(format: "Worst first wait %.0f ms of %.0f", worst * 1000, Self.limit * 1000)
		budget.textColor = worst > Self.limit + 0.001 ? .systemRed : .secondaryLabelColor
		for update in controls { update() }
	}

	private func changed() {
		refresh()
		save?.cancel()
		save = Task {
			try? await Task.sleep(for: .milliseconds(300))
			guard !Task.isCancelled else { return }
			try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
			if let data = try? JSONSerialization.data(withJSONObject: tuning.json, options: [.prettyPrinted, .sortedKeys]) {
				try? data.write(to: Self.file)
			}
		}
	}

	// MARK: Panel

	private func makePanel() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
			styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "Cursor Lab"
		window.level = .floating
		window.isReleasedWhenClosed = false
		if let screen = NSScreen.main?.visibleFrame {
			window.setFrame(NSRect(x: screen.maxX - 400, y: screen.maxY - 780, width: 380, height: min(760, screen.height - 40)), display: false)
		}

		let stack = NSStackView()
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)

		sendButton = NSButton(title: "Send agents", target: self, action: #selector(send))
		sendButton.keyEquivalent = "\r"
		let loop = NSButton(checkboxWithTitle: "Loop", target: self, action: #selector(toggleLoop(_:)))
		controls.append { [unowned self] in loop.state = tuning.loop ? .on : .off }
		stack.addArrangedSubview(row([sendButton, loop]))
		budget.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
		waits.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		waits.textColor = .secondaryLabelColor
		stack.addArrangedSubview(budget)
		stack.addArrangedSubview(waits)

		stack.addArrangedSubview(choice("Breakout", Defaults.breakouts, get: { $0.breakout }, set: { $0.breakout = $1 }))
		stack.addArrangedSubview(choice("Agents", ["1", "2", "3"], get: { $0.agents - 1 }, set: { $0.agents = $1 + 1 }))
		stack.addArrangedSubview(choice("When done", Defaults.endings, get: { $0.ending }, set: { $0.ending = $1 }))
		stack.addArrangedSubview(choice("Speed", Defaults.speeds.map(\.label), get: { $0.speed }, set: { $0.speed = $1 }))

		stack.addArrangedSubview(heading("Principles"))
		for flag in Defaults.flags {
			let box = NSButton(checkboxWithTitle: flag.label, target: self, action: #selector(toggleFlag(_:)))
			box.identifier = NSUserInterfaceItemIdentifier(flag.key)
			controls.append { [unowned self] in box.state = tuning.on(flag.key) ? .on : .off }
			stack.addArrangedSubview(box)
		}

		var section = ""
		for knob in Defaults.knobs {
			if knob.section != section {
				section = knob.section
				stack.addArrangedSubview(heading(section))
			}
			stack.addArrangedSubview(slider(knob))
		}

		let copy = NSButton(title: "Copy values", target: self, action: #selector(copyValues))
		let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetValues))
		stack.addArrangedSubview(row([copy, reset]))
		let note = NSTextField(wrappingLabelWithString: "Saved as you change them to \(Self.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
		note.font = .systemFont(ofSize: 10)
		note.textColor = .tertiaryLabelColor
		stack.addArrangedSubview(note)

		let document = Flipped()
		document.translatesAutoresizingMaskIntoConstraints = false
		stack.translatesAutoresizingMaskIntoConstraints = false
		document.addSubview(stack)
		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		scroll.documentView = document
		window.contentView = scroll
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
			stack.topAnchor.constraint(equalTo: document.topAnchor),
			stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
			document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
		])
		for view in stack.arrangedSubviews where !(view is NSButton) {
			view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
		}
		return window
	}

	private func row(_ views: [NSView]) -> NSStackView {
		let row = NSStackView(views: views)
		row.orientation = .horizontal
		row.spacing = 10
		return row
	}

	private func heading(_ title: String) -> NSView {
		let label = NSTextField(labelWithString: title.uppercased())
		label.font = .systemFont(ofSize: 10, weight: .semibold)
		label.textColor = .secondaryLabelColor
		let box = NSStackView(views: [label])
		box.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
		return box
	}

	private func choice(_ title: String, _ labels: [String], get: @escaping (Tuning) -> Int, set: @escaping (Tuning, Int) -> Void) -> NSView {
		let control = Segmented(labels: labels, trackingMode: .selectOne, target: self, action: #selector(choose(_:)))
		control.apply = { [unowned self] index in set(tuning, index) }
		controls.append { [unowned self] in control.selectedSegment = get(tuning) }
		let label = NSTextField(labelWithString: title)
		label.widthAnchor.constraint(equalToConstant: 80).isActive = true
		return row([label, control])
	}

	private func slider(_ knob: Knob) -> NSView {
		let label = NSTextField(labelWithString: knob.label)
		label.font = .systemFont(ofSize: 11)
		label.widthAnchor.constraint(equalToConstant: 130).isActive = true
		let slider = NSSlider(value: knob.value, minValue: knob.range.lowerBound, maxValue: knob.range.upperBound,
			target: self, action: #selector(slide(_:)))
		slider.identifier = NSUserInterfaceItemIdentifier(knob.key)
		slider.controlSize = .small
		let value = NSTextField(labelWithString: "")
		value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		value.alignment = .right
		value.widthAnchor.constraint(equalToConstant: 72).isActive = true
		controls.append { [unowned self] in
			let current = tuning[knob.key]
			slider.doubleValue = current
			let digits = knob.range.upperBound <= 3 ? 2 : 0
			value.stringValue = String(format: "%.\(digits)f", current) + (knob.unit.isEmpty ? "" : " \(knob.unit)")
		}
		return row([label, slider, value])
	}

	// MARK: Actions

	@objc private func send() {
		if sendButton.title == "Stop" { return engine.stop() }
		measured = [:]
		waits.stringValue = ""
		engine.send()
	}

	@objc private func toggleLoop(_ sender: NSButton) {
		tuning.loop = sender.state == .on
		changed()
	}

	@objc private func toggleFlag(_ sender: NSButton) {
		guard let key = sender.identifier?.rawValue else { return }
		tuning.flags[key] = sender.state == .on
		changed()
	}

	@objc private func choose(_ sender: Segmented) {
		sender.apply?(sender.selectedSegment)
		changed()
	}

	@objc private func slide(_ sender: NSSlider) {
		guard let key = sender.identifier?.rawValue else { return }
		let knob = Defaults.knobs.first { $0.key == key }
		// Whole numbers above a few units: milliseconds, points and degrees don't need fractions.
		let value = (knob?.range.upperBound ?? 0) > 3 ? sender.doubleValue.rounded() : (sender.doubleValue * 100).rounded() / 100
		tuning.values[key] = value
		changed()
	}

	@objc private func copyValues() {
		guard let data = try? JSONSerialization.data(withJSONObject: tuning.json, options: [.prettyPrinted, .sortedKeys]) else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
	}

	@objc private func resetValues() {
		let fresh = Tuning()
		tuning.values = fresh.values
		tuning.flags = fresh.flags
		tuning.breakout = fresh.breakout
		tuning.ending = fresh.ending
		tuning.agents = fresh.agents
		tuning.speed = fresh.speed
		tuning.loop = fresh.loop
		changed()
	}
}

final class Flipped: NSView {
	override var isFlipped: Bool { true }
}

final class Segmented: NSSegmentedControl {
	var apply: ((Int) -> Void)?
}

// MARK: Scenes

/// Three windows for agents to work in, after the exploration's Notes, Calendar and Terminal.
@MainActor
enum Scenes {
	static func make() -> [NSWindow] {
		let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
		let room = NSRect(x: screen.minX + 40, y: screen.minY + 40, width: max(screen.width - 480, 700), height: screen.height - 80)
		return [
			window("Notes", NSRect(x: room.minX, y: room.maxY - 320, width: 420, height: 300), notes()),
			window("Calendar", NSRect(x: room.minX + room.width * 0.5, y: room.maxY - 380, width: 420, height: 340), Calendar()),
			window("Terminal", NSRect(x: room.minX + room.width * 0.18, y: room.minY + 40, width: 540, height: 280), terminal()),
		]
	}

	private static func window(_ title: String, _ frame: NSRect, _ content: NSView) -> NSWindow {
		let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
			backing: .buffered, defer: false)
		window.title = title
		window.isReleasedWhenClosed = false
		window.contentView = content
		window.setFrame(frame, display: false)
		return window
	}

	private static func notes() -> NSView {
		let scroll = NSTextView.scrollableTextView()
		let text = scroll.documentView as? NSTextView
		text?.string = "Groceries\n\n• Eggs\n• Coffee beans\n• Lemons\n"
		text?.font = .systemFont(ofSize: 15)
		text?.textContainerInset = NSSize(width: 16, height: 16)
		return scroll
	}

	private static func terminal() -> NSView {
		let scroll = NSTextView.scrollableTextView()
		let text = scroll.documentView as? NSTextView
		text?.string = "~/code/prompt-bench $ "
		text?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
		text?.backgroundColor = NSColor(white: 0.1, alpha: 1)
		text?.textColor = NSColor(white: 0.9, alpha: 1)
		text?.insertionPointColor = .white
		text?.textContainerInset = NSSize(width: 12, height: 12)
		return scroll
	}

	final class Calendar: NSView {
		override func draw(_: NSRect) {
			NSColor.windowBackgroundColor.setFill()
			bounds.fill()
			let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.labelColor]
			("October 2026" as NSString).draw(at: NSPoint(x: 18, y: bounds.maxY - 38), withAttributes: title)
			let grid = NSRect(x: 14, y: 14, width: bounds.width - 28, height: bounds.height - 64)
			let cell = NSSize(width: grid.width / 7, height: grid.height / 5)
			let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
			NSColor.separatorColor.setStroke()
			// October 2026 starts on a Thursday.
			for index in 0..<35 {
				let column = index % 7, line = index / 7
				let rect = NSRect(x: grid.minX + CGFloat(column) * cell.width, y: grid.maxY - CGFloat(line + 1) * cell.height,
					width: cell.width, height: cell.height)
				NSBezierPath(rect: rect).stroke()
				let day = index - 3
				if (1...31).contains(day) {
					("\(day)" as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.maxY - 16), withAttributes: small)
				}
			}
		}
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let lab = MainActor.assumeIsolated { Lab() }
app.delegate = lab
app.run()
