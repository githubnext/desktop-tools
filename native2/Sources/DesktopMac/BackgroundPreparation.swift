import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Ported from Peekaboo's BackgroundWindowKeyboardPreparation, BackgroundWindowActivationDriver,
// BackgroundWindowChromeReader and BackgroundWindowChromeGeometry (MIT).
//
// An app that isn't active takes a background Command-V only once its window is key: TextEdit and Finder both drop
// it otherwise. Peekaboo makes the window key without activating the app, with a SkyLight activation record and a
// window-routed click on blank title-bar chrome, and only then sends the keys.

/// Preparation sent input and then stopped, so no keys were sent but the app may have seen the activation or click.
struct PreparationStopped: Error {
	let units: Int
	let cause: String
}

/// Blank title-bar chrome: the row of the window's traffic lights, minus every element drawn in it.
struct TitleBarGeometry {
	let bounds: CGRect
	let controls: [CGRect]
	let occupied: [CGRect]

	private static let clearance: CGFloat = 4

	var row: ClosedRange<CGFloat>? {
		guard Self.usable(bounds), controls.count == 3, controls.allSatisfy({ Self.usable($0) && bounds.contains($0) }),
		      let top = controls.map(\.minY).max(), let bottom = controls.map(\.maxY).min()
		else { return nil }
		let lower = top + Self.clearance, upper = bottom - Self.clearance
		return lower < upper ? lower...upper : nil
	}

	/// The middle of the widest gap in the row, at least twice the clearance wide.
	func point() -> CGPoint? {
		guard let row else { return nil }
		let y = row.lowerBound + (row.upperBound - row.lowerBound) / 2
		guard let gap = gaps(at: y).max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
		return CGPoint(x: gap.lowerBound + (gap.upperBound - gap.lowerBound) / 2, y: y)
	}

	private func gaps(at y: CGFloat) -> [ClosedRange<CGFloat>] {
		let left = bounds.minX + Self.clearance, right = bounds.maxX - Self.clearance
		guard left < right else { return [] }
		var gaps = [left...right]
		for frame in controls + occupied where Self.usable(frame) {
			let excluded = frame.insetBy(dx: -Self.clearance, dy: -Self.clearance)
			guard y >= excluded.minY, y <= excluded.maxY else { continue }
			gaps = gaps.flatMap { gap -> [ClosedRange<CGFloat>] in
				guard excluded.maxX > gap.lowerBound, excluded.minX < gap.upperBound else { return [gap] }
				var remaining: [ClosedRange<CGFloat>] = []
				if excluded.minX > gap.lowerBound { remaining.append(gap.lowerBound...min(gap.upperBound, excluded.minX)) }
				if excluded.maxX < gap.upperBound { remaining.append(max(gap.lowerBound, excluded.maxX)...gap.upperBound) }
				return remaining
			}
		}
		return gaps.filter { $0.upperBound - $0.lowerBound >= Self.clearance * 2 }
	}

	private static func usable(_ frame: CGRect) -> Bool {
		[frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
	}
}

/// The SkyLight event record that makes one window key in its process, without bringing the app forward.
func activationRecord(windowID: CGWindowID) -> [UInt8] {
	var record = [UInt8](repeating: 0, count: 0xF8)
	record[0x04] = 0xF8
	record[0x08] = 0x0D
	record[0x8A] = 0x01
	for byte in 0..<4 { record[0x3C + byte] = UInt8(truncatingIfNeeded: windowID >> (byte * 8)) }
	return record
}

private let activation: (
	processForPID: (@convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32)?,
	pidForProcess: (@convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32)?,
	post: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32)?
) = {
	let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
	let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
	return (
		services.flatMap { dlsym($0, "GetProcessForPID") }.map { unsafeBitCast($0, to: (@convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32).self) },
		services.flatMap { dlsym($0, "GetProcessPID") }.map { unsafeBitCast($0, to: (@convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32).self) },
		skyLight.flatMap { dlsym($0, "SLPSPostEventRecordTo") }.map { unsafeBitCast($0, to: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32).self) }
	)
}()

extension Mac {
	/// Whether the window's app is the active one, so keys it is sent go to its key window as typed.
	static func isActive(_ window: ClickWindow) -> Bool {
		frontmost().map { $0.pid == window.pid && $0.generation == window.generation } == true
	}

	/// Makes an inactive app's exact window key: an activation record, then a routed click on its blank title bar.
	/// Throws Refusal when nothing was sent, and PreparationStopped once something was. Returns the units sent.
	static func prepareBackgroundWindow(_ window: ClickWindow) throws -> Int {
		func refused(_ cause: String) -> Refusal {
			Refusal("DESKTOP_ACTION_FAILED", "The background window couldn't be prepared for keyboard input, so nothing was sent: \(cause)",
			        hint: "Bring the window forward with desktop_focus, inspect it again, and retry.")
		}
		guard CGPreflightPostEventAccess() else { throw refused("event posting isn't allowed.") }
		try window.check()
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 0.5)
		let matches = (AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { AX.windowID($0) == window.windowID }
		guard matches.count == 1, let element = matches.first else { throw refused("its window has no unique Accessibility element.") }
		AXUIElementSetMessagingTimeout(element, 0.5)
		guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
		      AX.value(element, kAXMinimizedAttribute) as? Bool != true, AX.value(element, "AXFullScreen") as? Bool != true,
		      (AX.value(element, "AXSheets") as? [AXUIElement] ?? []).isEmpty
		else { throw refused("it isn't a standard window without a sheet.") }
		let controls = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].compactMap { name in
			AX.element(AX.value(element, name)).flatMap(AX.frame)
		}
		// Everything drawn in the title row is excluded; a subtree outside the row is skipped, since AppKit keeps
		// children inside their parents.
		var geometry = TitleBarGeometry(bounds: window.bounds, controls: controls, occupied: [])
		guard let row = geometry.row else { throw refused("its title bar has no standard window controls.") }
		let band = CGRect(x: window.bounds.minX, y: row.lowerBound - 4, width: window.bounds.width, height: row.upperBound - row.lowerBound + 8)
		var occupied: [CGRect] = []
		var queue = AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
		var visited = 0
		while !queue.isEmpty {
			let node = queue.removeFirst()
			visited += 1
			guard visited <= 512 else { throw refused("its window has too many elements in the title row.") }
			AXUIElementSetMessagingTimeout(node, 0.5)
			guard let frame = AX.frame(node), frame.intersects(band) else { continue }
			occupied.append(frame)
			queue += AX.value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
		}
		geometry = TitleBarGeometry(bounds: window.bounds, controls: controls, occupied: occupied)
		guard let point = geometry.point() else { throw refused("its title bar has no blank space to click.") }
		var hit: AXUIElement?
		guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit, CFEqual(hit, element) else {
			throw refused("the title-bar point doesn't hit the window itself.")
		}

		guard let processForPID = activation.processForPID, let pidForProcess = activation.pidForProcess, let post = activation.post,
		      let windowID = CGWindowID(exactly: window.windowID)
		else { throw refused("background window activation is unavailable on this system.") }
		var psn: [UInt32] = [0, 0]
		var reverse: pid_t = 0
		guard psn.withUnsafeMutableBytes({ processForPID(window.pid, $0.baseAddress!) }) == 0,
		      psn.withUnsafeBytes({ pidForProcess($0.baseAddress!, &reverse) }) == 0, reverse == window.pid
		else { throw refused("its process couldn't be resolved.") }
		try window.check()
		let record = activationRecord(windowID: windowID)
		let posted = psn.withUnsafeBytes { recipient in record.withUnsafeBytes { post(recipient.baseAddress!, $0.baseAddress!) } }
		guard posted == 0 else { throw PreparationStopped(units: 1, cause: "The window activation returned an uncertain result.") }
		do { try window.check() } catch { throw PreparationStopped(units: 1, cause: "The window changed after its activation.") }
		let click: Delivery
		do { click = try routedClick(at: point, kind: .single, window: window) } catch {
			throw PreparationStopped(units: 1, cause: "The title-bar click wasn't sent: \(error)")
		}
		let units = 1 + (click.units ?? 0)
		guard click.state != .indeterminate else { throw PreparationStopped(units: units, cause: "The title-bar click was interrupted.") }
		// Let the window become key before keys follow.
		Thread.sleep(forTimeInterval: 0.05)
		return units
	}
}
