// Ported from native/Sources/runtime's watch.swift.
import Darwin
import Dispatch
import Foundation

/// Watches a published socket path and calls `lost` once when the path no longer names the socket this host bound,
/// because it was removed or replaced. Clients find the host only through that path, so a host whose socket is gone
/// serves nobody until it publishes again.
@MainActor
final class SocketWatch {
	private let path: String
	private let identity: (dev_t, ino_t)
	private let lost: @MainActor () -> Void
	private var directory: DispatchSourceFileSystemObject?
	private var timer: Timer?

	/// Nil when `path` isn't a socket now, so there is nothing to watch.
	init?(path: String, lost: @escaping @MainActor () -> Void) {
		guard let identity = Self.identity(path) else { return nil }
		self.path = path
		self.identity = identity
		self.lost = lost
		// Changes to the folder catch a removal at once; the timer catches anything the folder events miss.
		let folder = open((path as NSString).deletingLastPathComponent, O_EVTONLY | O_CLOEXEC)
		if folder >= 0 {
			let source = DispatchSource.makeFileSystemObjectSource(
				fileDescriptor: folder, eventMask: [.write, .rename, .delete], queue: .main)
			source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.check() } }
			source.setCancelHandler { close(folder) }
			source.resume()
			directory = source
		}
		timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.check() }
		}
	}

	/// Calls `lost` and stops watching when the path no longer names the bound socket.
	func check() {
		guard directory != nil || timer != nil else { return }
		if let current = Self.identity(path), current == identity { return }
		cancel()
		lost()
	}

	func cancel() {
		directory?.cancel()
		directory = nil
		timer?.invalidate()
		timer = nil
	}

	private static func identity(_ path: String) -> (dev_t, ino_t)? {
		var info = stat()
		guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
		return (info.st_dev, info.st_ino)
	}
}
