import AppKit
import CoreGraphics
import DesktopProtocol

extension Mac {
	/// Running applications by ascending PID, each with its process generation, as desktop_apps lists them.
	///
	/// Peekaboo read identity and presentation in two host round trips and matched them up again; here both
	/// come from one pass, so a row's activity is known whenever exactly one app is frontmost.
	public static func apps() async throws -> JSON {
		let (rows, inventoryWarnings) = await MainActor.run { inventory() }
		// Read after the inventory; its focus read has its own short limit.
		let system = await systemState()
		var metadataWarnings: [String] = []
		let activityKnown = rows.filter(\.isActive).count == 1
		if !activityKnown {
			metadataWarnings.append("No unique active application with matching process-generation identity was observed; activity is unknown.")
		}
		return .object([
			("apps", .array(rows.map { $0.json(activityKnown: activityKnown) })),
			("inventory_completeness", inventoryWarnings.isEmpty ? "complete" : "partial"),
			("inventory_warnings", .array(inventoryWarnings.map(JSON.string))),
			("metadata_warnings", .array(metadataWarnings.map(JSON.string))),
			("system", system),
		])
	}

	struct AppRow {
		let pid: pid_t
		let generation: UInt64
		let name: String
		let bundleID: String?
		let isActive: Bool
		let isHidden: Bool
		let warnings: [String]

		func json(activityKnown: Bool) -> JSON {
			let identity = JSON(String(generation))
			return .object([
				"name": JSON(name),
				"pid": JSON(pid),
				"bundle_id": bundleID.map(JSON.string),
				"is_active": activityKnown ? JSON(isActive) : nil,
				"is_active_known": JSON(activityKnown),
				"is_hidden": JSON(isHidden),
				"is_hidden_known": true,
				"process_start_identity_decimal": identity,
				"warnings": warnings.isEmpty ? nil : .array(warnings.map(JSON.string)),
				"target": .object([("pid", JSON(pid)), ("process_start_identity_decimal", identity)]),
			])
		}
	}

	@MainActor static func inventory() -> ([AppRow], [String]) {
		let workspace = NSWorkspace.shared
		let pids = Array(Set(workspace.runningApplications.map(\.processIdentifier))).filter { $0 > 0 }.sorted()
		let frontmost = workspace.frontmostApplication?.processIdentifier
		let catalog = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) != nil
		var rows: [AppRow] = []
		var warnings: [String] = []
		for pid in pids {
			let app = NSRunningApplication(processIdentifier: pid).flatMap { $0.isTerminated ? nil : $0 }
			let first = startIdentity(pid)
			guard let generation = first.value else {
				if first == .absent, startIdentity(pid) == .absent { continue }
				if first == .permissionDenied, foreignProhibited(pid) { continue }
				let label = app.map { " (\($0.localizedName ?? $0.bundleIdentifier ?? "Unknown"))" } ?? ""
				warnings.append("Application PID \(pid)\(label) lacked process-generation identity and was omitted.")
				continue
			}
			guard let app else {
				warnings.append("Application PID \(pid) metadata was unavailable and was omitted.")
				continue
			}
			guard startIdentity(pid).value == generation else {
				warnings.append("Application PID \(pid) changed process generation during inventory and was omitted.")
				continue
			}
			let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
			guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				warnings.append("Application PID \(pid) metadata lacked a usable name and was omitted.")
				continue
			}
			rows.append(AppRow(
				pid: pid,
				generation: generation,
				name: name,
				bundleID: app.bundleIdentifier,
				isActive: frontmost == pid,
				isHidden: app.isHidden,
				warnings: catalog ? [] : ["Window inventory was unavailable for PID \(pid)"]
			))
		}
		return (rows, warnings)
	}
}
