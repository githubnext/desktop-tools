import CoreGraphics
@testable import DesktopMac
import Foundation
import Testing

private final class Flag: @unchecked Sendable {
	var value = false
}

/// Some other process's on-screen window, so a reservation on it stays unresolved.
private func liveWindow() -> (pid: pid_t, generation: UInt64, windowID: Int)? {
	let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
	for info in list {
		guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(getpid()),
		      let id = info[kCGWindowNumber as String] as? Int, let generation = Mac.generation(pid_t(pid))
		else { continue }
		return (pid_t(pid), generation, id)
	}
	return nil
}

private func lockPath() -> String {
	NSTemporaryDirectory() + "clipboard-gate-\(UUID())/clipboard-paste-transaction.lock"
}

@Suite(.serialized)
struct ClipboardGateTests {
	@Test(.enabled(if: liveWindow() != nil))
	func `a pending paste refuses the next transaction until its receiver shows it`() throws {
		let path = lockPath(), window = liveWindow()!, consumed = Flag()
		try ClipboardGate.exclusive(path: path) { transaction in
			_ = try transaction.reservePaste(pid: window.pid, generation: window.generation, windowID: window.windowID) { consumed.value }
			#expect(transaction.hasUnresolvedPaste)
		}
		#expect(throws: Refusal.self) { try ClipboardGate.exclusive(path: path) { _ in } }
		consumed.value = true
		try ClipboardGate.exclusive(path: path) { #expect(!$0.hasUnresolvedPaste) }
		#expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
	}

	@Test
	func `a closed receiver window releases the reservation`() throws {
		let path = lockPath()
		try ClipboardGate.exclusive(path: path) { transaction in
			_ = try transaction.reservePaste(pid: getpid(), generation: Mac.generation(getpid())!, windowID: Int(Int32.max) - 7) { false }
		}
		try ClipboardGate.exclusive(path: path) { #expect(!$0.hasUnresolvedPaste) }
	}

	@Test
	func `the record is Peekaboo's, so both stacks honour it`() throws {
		let path = lockPath()
		try ClipboardGate.exclusive(path: path) { transaction in
			let id = try transaction.reservePaste(pid: getpid(), generation: 42, windowID: 7) { false }
			let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
			#expect(Set(record?.keys.map { $0 } ?? []) == ["version", "id", "pid", "processStartIdentity", "windowID"])
			#expect(record?["id"] as? String == id.uuidString && record?["version"] as? Int == 1)
			try transaction.releasePaste(id)
		}
	}

	@Test
	func `an unreadable record refuses every transaction`() throws {
		let path = lockPath()
		try ClipboardGate.exclusive(path: path) { _ in }
		try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
		#expect(throws: Refusal.self) { try ClipboardGate.exclusive(path: path) { _ in } }
	}

	@Test
	func `an unavailable window list proves nothing`() {
		#expect(!ClipboardGate.windowClosed(pid: 1, windowInfo: nil))
		#expect(ClipboardGate.windowClosed(pid: 1, windowInfo: []))
		#expect(!ClipboardGate.windowClosed(pid: 1, windowInfo: [[kCGWindowOwnerPID as String: 1]]))
	}
}
