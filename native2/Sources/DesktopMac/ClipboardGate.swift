import CoreGraphics
import Darwin
import Foundation

// Ported from Peekaboo's ClipboardPasteTransactionGate (MIT).
//
// A paste whose Command-V may still be pending leaves its payload on the clipboard, so a later clipboard write would be
// pasted in its place. Every clipboard write and paste runs holding one file lock, and a paste records itself in that
// file just before Command-V. The next transaction is refused until the paste's edit is seen, its receiver's window
// closes, or its process ends. The lock file and its record are Peekaboo's, so the shipped stack and this one honour
// each other's pending pastes.

/// A clipboard write or paste, holding the shared lock. A paste reserves the clipboard through it.
final class ClipboardTransaction {
	fileprivate struct Reservation: Codable {
		let version: Int
		let id: UUID
		let pid: Int32
		let processStartIdentity: UInt64
		let windowID: Int
	}

	fileprivate let descriptor: Int32
	fileprivate let path: String
	fileprivate var reservation: Reservation?

	fileprivate init(descriptor: Int32, path: String) {
		self.descriptor = descriptor
		self.path = path
	}

	/// Records a paste about to send Command-V. Called only before the key goes down; `canRelease` later shows
	/// whether the receiver consumed it, and must not hold the prior clipboard.
	func reservePaste(pid: pid_t, generation: UInt64, windowID: Int, canRelease: @escaping () -> Bool) throws -> UUID {
		guard reservation == nil else { throw ClipboardGate.failure("A clipboard transaction can reserve only one paste.") }
		let value = Reservation(version: 1, id: UUID(), pid: pid, processStartIdentity: generation, windowID: windowID)
		// A failed write can't be followed by Command-V; on cleanup failure the uncertain record stays.
		do { try write(value) } catch {
			try? write(nil)
			throw error
		}
		ClipboardGate.setPending(.init(id: value.id, path: path, canRelease: canRelease))
		return value.id
	}

	func releasePaste(_ id: UUID) throws {
		guard reservation?.id == id else { throw ClipboardGate.failure("The clipboard reservation being released isn't this transaction's.") }
		try write(nil)
		ClipboardGate.clearPending(id)
	}

	var hasUnresolvedPaste: Bool { reservation != nil }

	fileprivate func read() throws -> Reservation? {
		var info = stat()
		guard fstat(descriptor, &info) == 0 else { throw systemFailure("inspect reservation") }
		if info.st_size == 0 { return nil }
		guard info.st_size > 0, info.st_size <= 2048 else { throw ClipboardGate.invalid(path) }
		var data = Data(count: Int(info.st_size))
		let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, $0.count, 0) }
		guard count == data.count, let value = try? JSONDecoder().decode(Reservation.self, from: data),
		      value.version == 1, value.pid > 0, value.processStartIdentity > 0, value.windowID > 0
		else { throw ClipboardGate.invalid(path) }
		return value
	}

	fileprivate func write(_ value: Reservation?) throws {
		let data = try value.map { try JSONEncoder().encode($0) } ?? Data()
		guard ftruncate(descriptor, 0) == 0 else { throw systemFailure("truncate reservation") }
		var offset = 0
		while offset < data.count {
			let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
			if written < 0, errno == EINTR { continue }
			guard written > 0 else { throw systemFailure("write reservation") }
			offset += written
		}
		guard fsync(descriptor) == 0 else { throw systemFailure("sync reservation") }
		reservation = value
	}

	private func systemFailure(_ operation: String) -> ToolFailure {
		ClipboardGate.failure("Clipboard paste transaction lock failed during \(operation) at \(path): \(String(cString: strerror(errno)))")
	}
}

enum ClipboardGate {
	/// Matches the exclusive capture and desktop-mutation lock waits.
	static let maximumWait: Duration = .seconds(15)

	static var defaultPath: String {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
		return support.appendingPathComponent("Peekaboo/clipboard-paste-transaction.lock").standardizedFileURL.path
	}

	/// This host's own pending paste, whose receiver it can still read to see the paste consumed.
	fileprivate struct Pending {
		let id: UUID
		let path: String
		let canRelease: () -> Bool
	}

	nonisolated(unsafe) private static var pending: Pending?
	private static let pendingLock = NSLock()

	fileprivate static func setPending(_ value: Pending) { pendingLock.withLock { pending = value } }
	fileprivate static func clearPending(_ id: UUID) { pendingLock.withLock { if pending?.id == id { pending = nil } } }

	/// Runs `work` holding the shared lock, once no earlier paste is left unresolved. Throws Refusal when the lock
	/// can't be had in time or a paste is still pending, before `work` runs.
	static func exclusive<T>(path: String = defaultPath, wait: Duration = maximumWait, _ work: (ClipboardTransaction) throws -> T) throws -> T {
		let deadline = ContinuousClock.now + wait
		let path = URL(fileURLWithPath: path).standardizedFileURL.path
		try prepareDirectory(for: path)
		let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
		guard descriptor >= 0 else { throw failure("Clipboard paste transaction lock failed during open at \(path): \(String(cString: strerror(errno)))") }
		defer { close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
			throw failure("Clipboard paste transaction lock is not a regular file owned by the current user: \(path)")
		}
		// flock is held per open file, so two transactions in this host exclude each other as two processes do.
		while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
			guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
				throw failure("Clipboard paste transaction lock failed during flock at \(path): \(String(cString: strerror(errno)))")
			}
			guard ContinuousClock.now < deadline else {
				throw Refusal("TIMEOUT", "Timed out waiting for the exclusive clipboard paste transaction lock at \(path).")
			}
			Thread.sleep(forTimeInterval: 0.01)
		}
		defer { flock(descriptor, LOCK_UN) }
		let transaction = ClipboardTransaction(descriptor: descriptor, path: path)
		do { try admit(transaction) } catch let refusal as Refusal { throw refusal } catch {
			throw Refusal("DESKTOP_ACTION_FAILED", "Shared clipboard ownership could not be verified before this operation.", hint: String(describing: error))
		}
		return try work(transaction)
	}

	/// Clears a reservation its receiver no longer holds, or refuses.
	private static func admit(_ transaction: ClipboardTransaction) throws {
		transaction.reservation = try transaction.read()
		guard let reservation = transaction.reservation else {
			pendingLock.withLock { if pending?.path == transaction.path { pending = nil } }
			return
		}
		var resolved = generationEnded(reservation) || windowClosed(pid: reservation.pid, windowInfo: windowInfo(reservation.windowID))
		if !resolved, let proof = pendingLock.withLock({ pending }), proof.path == transaction.path, proof.id == reservation.id {
			resolved = proof.canRelease()
		}
		if resolved { return try transaction.releasePaste(reservation.id) }
		throw Refusal(
			"DESKTOP_ACTION_FAILED", "A previous clipboard paste to process \(reservation.pid), window \(reservation.windowID) remains unresolved.",
			hint: "No new clipboard mutation was sent. Inspect the original receiver; its observed consumption, closing that window, or the original process quitting resolves ownership."
		)
	}

	private static func windowInfo(_ id: Int) -> [[String: Any]]? {
		CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]]
	}

	/// A closed receiver window can no longer take the pending paste. An unavailable window list proves nothing.
	static func windowClosed(pid: pid_t, windowInfo: [[String: Any]]?) -> Bool {
		guard let windowInfo else { return false }
		guard let owner = windowInfo.first?[kCGWindowOwnerPID as String] as? Int else { return true }
		return owner != Int(pid)
	}

	private static func generationEnded(_ reservation: ClipboardTransaction.Reservation) -> Bool {
		switch startIdentity(reservation.pid) {
		case let .identity(current): current != reservation.processStartIdentity
		case .absent: true
		case .permissionDenied, .unavailable: false
		}
	}

	private static func prepareDirectory(for path: String) throws {
		let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
		} catch {
			throw failure("Clipboard paste transaction lock failed during prepare at \(directory.path): \(error.localizedDescription)")
		}
		var info = stat()
		guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
			throw failure("Clipboard paste transaction lock directory is unsafe: \(directory.path)")
		}
	}

	fileprivate static func invalid(_ path: String) -> ToolFailure {
		failure("Clipboard paste reservation at \(path) is unreadable or unsupported. No new clipboard mutation was admitted; recover it only after the original receiver has terminated.")
	}

	fileprivate static func failure(_ message: String) -> ToolFailure { ToolFailure(message) }
}
