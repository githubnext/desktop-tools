@testable import DesktopMac
import Testing

/// A modifier click refused for held input names what it found held (#198).
struct HeldInputTests {
	static func activity(keys: [Int] = [], buttons: [Int] = []) -> InputActivity {
		InputActivity(
			moved: 0, leftDragged: 0, rightDragged: 0, otherDragged: 0, leftDown: 0, leftUp: 0, rightDown: 0, rightUp: 0,
			otherDown: 0, otherUp: 0, keyDown: 0, keyUp: 0, flagsChanged: 0, scrollWheel: 0,
			heldKeys: (0..<128).map { keys.contains($0) }, heldButtons: (0..<32).map { buttons.contains($0) }
		)
	}

	@Test
	func `held keys and buttons are named, modifiers and contract keys by name`() {
		let held = Self.activity(keys: [0x38, 0x35, 0x00], buttons: [0, 4])
		#expect(held.hasHeldInput)
		#expect(held.heldNames == ["key 0", "Escape (key 53)", "Shift (key 56)", "left mouse button", "mouse button 4"])
		#expect(spokenList(held.heldNames) == "key 0, Escape (key 53), Shift (key 56), left mouse button and mouse button 4")
	}

	@Test
	func `nothing held names nothing`() {
		#expect(!Self.activity().hasHeldInput)
		#expect(Self.activity().heldNames.isEmpty)
		#expect(spokenList(["Fn (key 63)"]) == "Fn (key 63)")
	}
}
