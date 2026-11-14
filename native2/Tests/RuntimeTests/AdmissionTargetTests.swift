import CoreGraphics
@testable import DesktopHost
import DesktopProtocol
import Foundation
import Testing

/// Admission checks every process a call's input can reach, whichever argument carries it: the snapshot, a
/// notification id's snapshot, a drag's to_snapshot, and an explicit pid, which must agree with the snapshot's.
@Suite(.serialized)
struct AdmissionTargetTests {
	/// A process that is neither this host, a protected app nor system UI.
	static let other: pid_t = 1

	static func snapshot(_ pid: pid_t) async -> String {
		let id = Snapshots.newID()
		await Snapshots.shared.put(Snapshot(
			id: id, pid: pid, generation: 0, windowID: 1, windowBounds: .zero, imageSize: .zero,
			elements: [:], focusedID: nil, lastUsed: Date()))
		return id
	}

	static func admission(_ name: String, _ arguments: [(String, JSON)]) async -> String? {
		Protected.shared.set([getpid()])
		defer { Protected.shared.set([]) }
		return await Tools.admission(name, arguments: .object(arguments), client: nil)
	}

	@Test
	func `input through the snapshot to the host's own window is refused`() async {
		let own = await Self.snapshot(getpid())
		let refusal = await Self.admission("desktop_click", [("snapshot", JSON(own)), ("element", "e1")])
		#expect(refusal?.hasPrefix("SELF_TARGET_REFUSED") == true)
	}

	@Test
	func `a decoy pid beside an own snapshot is refused`() async {
		let own = await Self.snapshot(getpid())
		let refusal = await Self.admission("desktop_click", [("snapshot", JSON(own)), ("element", "e1"), ("pid", JSON(Int(Self.other)))])
		#expect(refusal != nil)
	}

	@Test
	func `a decoy target pid beside an own snapshot is refused`() async {
		let own = await Self.snapshot(getpid())
		let refusal = await Self.admission(
			"desktop_click", [("snapshot", JSON(own)), ("element", "e1"), ("target", .object([("pid", JSON(Int(Self.other)))]))])
		#expect(refusal != nil)
	}

	@Test
	func `a pid that disagrees with the snapshot's is refused even for another app`() async {
		let other = await Self.snapshot(Self.other)
		let refusal = await Self.admission("desktop_click", [("snapshot", JSON(other)), ("element", "e1"), ("pid", JSON(Int(getpid()) + 100_000))])
		#expect(refusal != nil)
	}

	@Test
	func `a pid that agrees with the snapshot's is admitted`() async {
		let other = await Self.snapshot(Self.other)
		#expect(await Self.admission("desktop_click", [("snapshot", JSON(other)), ("element", "e1"), ("pid", JSON(Int(Self.other)))]) == nil)
		#expect(await Self.admission("desktop_click", [("snapshot", JSON(other)), ("element", "e1")]) == nil)
	}

	@Test
	func `a notification action whose id carries an own snapshot is refused`() async {
		let own = await Self.snapshot(getpid())
		let refusal = await Self.admission("desktop_notification_action", [("id", JSON("\(own)/e1")), ("action", "open")])
		#expect(refusal?.hasPrefix("SELF_TARGET_REFUSED") == true)
	}

	@Test
	func `a drag whose to_snapshot is an own window is refused`() async {
		let other = await Self.snapshot(Self.other)
		let own = await Self.snapshot(getpid())
		let refusal = await Self.admission("desktop_drag", [
			("snapshot", JSON(other)), ("to_snapshot", JSON(own)),
			("from", .object([("x", 0.1), ("y", 0.1)])), ("to", .object([("x", 0.5), ("y", 0.5)])),
		])
		#expect(refusal?.hasPrefix("SELF_TARGET_REFUSED") == true)
	}
}
