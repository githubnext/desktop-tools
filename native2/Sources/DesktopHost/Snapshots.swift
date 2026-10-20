import CoreGraphics
import DesktopMac
import DesktopProtocol
import Foundation

/// One inspection's evidence: the exact window it observed and the live elements an action may target.
struct Snapshot: @unchecked Sendable {
	let id: String
	let pid: pid_t
	let generation: UInt64
	let windowID: Int
	let windowBounds: CGRect
	/// Pixel size of the image the agent received, for fractional points.
	let imageSize: CGSize
	let elements: [String: Element]
	var lastUsed: Date
	/// An action spends the snapshot; the next action needs a fresh inspection.
	var spent = false
}

/// Snapshots live in the host's memory, where the Accessibility references they hold stay valid.
actor Snapshots {
	static let shared = Snapshots()
	private static let limit = 25
	private static let lifetime: TimeInterval = 600
	private var store: [String: Snapshot] = [:]

	static func newID() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return "ps1_" + bytes.map { String(format: "%02x", $0) }.joined()
	}

	func put(_ snapshot: Snapshot) {
		let now = Date()
		store = store.filter { now.timeIntervalSince($0.value.lastUsed) < Self.lifetime }
		while store.count >= Self.limit, let oldest = store.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
			store.removeValue(forKey: oldest.key)
		}
		store[snapshot.id] = snapshot
	}

	/// The snapshot for one action, which spends it.
	func spend(_ id: String) throws -> Snapshot {
		guard var snapshot = store[id], Date().timeIntervalSince(snapshot.lastUsed) < Self.lifetime else {
			throw ToolError("invalidRequest: Snapshot '\(id)' is unknown or expired. Inspect the window again.")
		}
		guard !snapshot.spent else {
			throw ToolError("invalidRequest: Snapshot is stale: Snapshot '\(id)' already drove a mutation whose result requires a fresh observation. Inspect the window again.")
		}
		snapshot.spent = true
		snapshot.lastUsed = Date()
		store[id] = snapshot
		return snapshot
	}

	func get(_ id: String) -> Snapshot? { store[id] }
}
