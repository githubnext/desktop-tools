import AppKit
import CoreGraphics
import DesktopProtocol

/// One CoreGraphics window row.
private struct CGRow {
	let id: Int
	let pid: pid_t
	let title: String
	let bounds: CGRect
	let isOnScreen: Bool
	let layer: Int
	let alpha: Double
	let sharing: Int?

	init?(_ info: [String: Any]) {
		guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
		      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
		      let raw = info[kCGWindowBounds as String] as? [String: Any],
		      let x = raw["X"] as? CGFloat, let y = raw["Y"] as? CGFloat,
		      let width = raw["Width"] as? CGFloat, let height = raw["Height"] as? CGFloat
		else { return nil }
		self.id = id
		self.pid = pid
		title = info[kCGWindowName as String] as? String ?? ""
		bounds = CGRect(x: x, y: y, width: width, height: height)
		isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
		layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
		alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
		sharing = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue
	}

	/// CoreGraphics parks a minimized window far off screen.
	var parked: Bool { bounds.origin.x < -10000 || bounds.origin.y < -10000 }

	/// Whether a capture of this window would show pixels, as Peekaboo's `WindowFiltering.isRenderable(.capture)` decides.
	var renderable: Bool {
		!parked && layer == 0 && alpha > 0.01 && sharing != 0 && isOnScreen && bounds.width >= 80 && bounds.height >= 40
	}
}

private func cgRows() -> [CGRow] {
	(CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap(CGRow.init)
}

/// One listed window before it becomes JSON.
private struct Row {
	let id: Int
	var title: String
	let bounds: CGRect
	var isOnScreen: Bool
	var isMinimized: Bool
	var isKey: Bool?
	var capability: String
	var reason: String?
}

private func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

extension Mac {
	/// One app's windows, as desktop_windows lists them: CoreGraphics' rows enriched by Accessibility, then
	/// windows only Accessibility knows. Each carries the evidence a later action checks before it acts.
	public static func windows(pid: pid_t) async throws -> JSON {
		let app = await MainActor.run { () -> (name: String, hidden: Bool)? in
			guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid && !$0.isTerminated })
			else { return nil }
			return (app.localizedName ?? app.bundleIdentifier ?? "Unknown", app.isHidden)
		}
		guard let app else { throw ToolError("notFound: Application 'PID:\(pid)' not found.") }
		guard let generation = startIdentity(pid).value else {
			throw ToolError("invalidRequest: Snapshot is stale: Application \(app.name) has no stable process generation for window listing. List desktop_apps again.")
		}

		let screenRecording = CGPreflightScreenCaptureAccess()
		let first = cgRows()
		let owned = screenRecording ? first.filter { $0.pid == pid } : []
		var warnings: [String] = []
		var rows: [Row] = []
		if NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
			warnings.append("Application appears to have terminated")
		} else {
			let ax = await withDeadline(.seconds(2)) { AX.windows(pid: pid) }
				?? AX.Windows(incomplete: true, timedOut: true)
			guard startIdentity(pid).value == generation else {
				throw ToolError("invalidRequest: Snapshot is stale: Target PID \(pid) changed process generation during window listing. List desktop_apps again.")
			}
			// A second read is the identity evidence: each row must still exist with the same owner and exact bounds.
			let second = Dictionary(cgRows().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
			let firstByID = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
			func key(_ id: Int?) -> Bool? { id.flatMap { id in ax.focusedID.map { $0 == id } } }

			let merged = !owned.isEmpty
			let axIncomplete = ax.timedOut || ax.incomplete || ax.reported > ax.descriptors.count
			var omittedCG = 0
			var seen = Set<Int>()
			if merged {
				let unmatched = axIncomplete
					? ("unknown", "accessibility_enumeration_incomplete")
					: ("pixels_only", "no_matching_accessibility_window")
				for cg in owned where seen.insert(cg.id).inserted {
					guard let again = second[cg.id], again.pid == pid, again.bounds == cg.bounds else {
						omittedCG += 1
						continue
					}
					var row = Row(id: cg.id, title: cg.title, bounds: cg.bounds, isOnScreen: cg.isOnScreen, isMinimized: cg.parked,
					              isKey: nil, capability: unmatched.0, reason: unmatched.1)
					if let ax = ax.descriptors.first(where: { $0.id == cg.id }) {
						row.isMinimized = ax.isMinimized ?? cg.parked
						row.isKey = key(cg.id)
						row.isOnScreen = row.isMinimized ? false : cg.isOnScreen
						row.capability = "combined_eligible"
						row.reason = nil
						if row.title.isEmpty { row.title = ax.title }
					}
					rows.append(row)
				}
			}

			// Windows only Accessibility lists, kept when CoreGraphics confirms them or they're minimized.
			// Every descriptor that neither enriched a CoreGraphics row nor became its own row counts as omitted.
			var omittedAX = ax.descriptors.filter { $0.id.map { !seen.contains($0) } ?? true }.count
			for descriptor in ax.descriptors where !descriptor.title.isEmpty && (descriptor.id.map { !seen.contains($0) } ?? true) {
				guard let bounds = descriptor.bounds else { continue }
				let id = descriptor.id ?? {
					let matches = first.filter { $0.pid == pid && $0.title == descriptor.title
						&& abs($0.bounds.minX - bounds.minX) <= 5 && abs($0.bounds.minY - bounds.minY) <= 5
						&& abs($0.bounds.width - bounds.width) <= 5 && abs($0.bounds.height - bounds.height) <= 5 }
					return matches.count == 1 ? matches[0].id : nil
				}()
				guard let id, seen.insert(id).inserted else { continue }
				let minimized = descriptor.isMinimized ?? false
				let cg = second[id]
				guard cg.map({ $0.pid == pid && $0.bounds == bounds }) ?? minimized else { continue }
				// Two identical reads of a capturable window make it eligible for combined observation.
				let stable = cg.flatMap { cg in firstByID[id].flatMap { $0.pid == cg.pid && $0.bounds == cg.bounds && cg.sharing != nil ? cg : nil } }
				omittedAX -= 1
				rows.append(Row(
					id: id, title: descriptor.title, bounds: bounds,
					isOnScreen: !minimized && (stable?.isOnScreen ?? true), isMinimized: minimized, isKey: key(id),
					capability: stable?.renderable == true ? "combined_eligible" : "unknown",
					reason: stable?.renderable == true ? nil : "raster_capture_unverified"
				))
			}

			if merged {
				if ax.timedOut { warnings.append("Window enumeration timed out after 2.0s, results may be incomplete") }
				if ax.incomplete { warnings.append("Accessibility window enrichment was incomplete; returning verified CG inventory") }
				if ax.reported > ax.descriptors.count {
					warnings.append("Accessibility reported \(ax.reported) windows; enriched \(ax.descriptors.count) before the bounded deadline")
				}
				if omittedCG > 0 { warnings.append("CoreGraphics omitted \(plural(omittedCG, "owner window row")) without complete identity evidence") }
				if omittedAX > 0 { warnings.append("Accessibility omitted \(plural(omittedAX, "unmatched window row")) without stable identity") }
			} else {
				if ax.timedOut { warnings.append("Window enumeration timed out, results may be incomplete") }
				if ax.incomplete { warnings.append("Accessibility window enumeration was incomplete") }
				if ax.reported > ax.descriptors.count { warnings.append("Only processed \(ax.descriptors.count) of \(ax.reported) accessible windows") }
				if omittedAX > 0 { warnings.append("Accessibility omitted \(plural(omittedAX, "window row")) without stable window identity") }
			}
		}
		warnings = Array(Set(warnings)).sorted()

		let places = WindowPlaces()
		let identity = JSON(String(generation))
		let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
		return .object([
			"pid": JSON(pid),
			"session_locked": JSON(session["CGSSessionScreenIsLocked"] as? Bool == true),
			"app_hidden": JSON(app.hidden),
			"windows": .array(rows.map { row in
				let place = places.place(row.bounds)
				let box = bounds(row.bounds)
				return .object([
					"window_id": JSON(row.id),
					"window_title": JSON(row.title),
					"bounds": box,
					"is_on_screen": JSON(row.isOnScreen),
					"is_minimized": JSON(row.isMinimized),
					"is_key": row.isKey.map(JSON.bool),
					"space_ids": .array(spaceIDs(window: row.id).map { JSON($0) }),
					"display_index": place.index.map { JSON($0) },
					"display_current_space_id": place.space.map { JSON($0) },
					"display_asleep": place.asleep.map(JSON.bool),
					"observation_capability": JSON(row.capability),
					"observation_reason": row.reason.map(JSON.string),
					"process_start_identity_decimal": identity,
					"target": .object([
						("pid", JSON(pid)), ("process_start_identity_decimal", identity), ("window_id", JSON(row.id)),
						("bounds", box), ("is_minimized", JSON(row.isMinimized)),
					]),
				])
			}),
			"inventory_completeness": warnings.isEmpty ? "complete" : "partial",
			"inventory_warnings": .array(warnings.map(JSON.string)),
		])
	}
}

/// The window that pointer events at a point would reach, as a refusal or an unverified hover names it.
public struct WindowAtPoint: Sendable, Equatable {
	public let id: Int
	public let pid: pid_t
	public let owner: String
	public let title: String
	public let layer: Int
	public let bounds: CGRect

	/// "window 123 of Ace ("Projects"), at layer 3".
	public var description: String {
		let name = title.isEmpty ? "" : " (\"\(title)\")"
		return "window \(id) of \(owner.isEmpty ? "PID \(pid)" : owner)\(name)\(layer == 0 ? "" : ", at layer \(layer)")"
	}
}

extension Mac {
	/// The topmost window at a global point that takes pointer events there. The window server's own hit test
	/// skips windows that let the pointer through, such as a screen recorder's frame or a web view's overlay,
	/// which the window list can't tell from cover (#196); the window list's topmost row is the fallback when no
	/// hit test is available. The host's own windows, such as Desktop Tools' highlight around the target, never count.
	public static func window(at point: CGPoint) -> WindowAtPoint? {
		let hosts = Set([getpid()] + NSRunningApplication.runningApplications(withBundleIdentifier: "dev.githubnext.desktop-tools").map(\.processIdentifier))
		let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
		let hostWindows = Set(all.filter { hosts.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }.compactMap { $0[kCGWindowNumber as String] as? Int })
		let rows = all.filter { row in
			!hosts.contains(row[kCGWindowOwnerPID as String] as? pid_t ?? 0) && (row[kCGWindowAlpha as String] as? Double ?? 1) > 0
				&& (row[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(point) == true
		}
		func found(_ row: [String: Any]) -> WindowAtPoint? {
			guard let id = row[kCGWindowNumber as String] as? Int, let pid = row[kCGWindowOwnerPID as String] as? pid_t,
			      let raw = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw)
			else { return nil }
			return WindowAtPoint(
				id: id, pid: pid, owner: row[kCGWindowOwnerName as String] as? String ?? "", title: row[kCGWindowName as String] as? String ?? "",
				layer: row[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds
			)
		}
		// NSWindow's coordinates start at the bottom of the main display.
		let flipped = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
		let hitTest = { () -> Int in
			var below = 0
			for _ in 0..<8 {
				let number = NSWindow.windowNumber(at: flipped, belowWindowWithWindowNumber: below)
				guard number > 0, hostWindows.contains(number) else { return number }
				below = number
			}
			return 0
		}
		let hit = Thread.isMainThread ? hitTest() : DispatchQueue.main.sync(execute: hitTest)
		if hit > 0, let row = all.first(where: { $0[kCGWindowNumber as String] as? Int == hit }) { return found(row) }
		return rows.first.flatMap(found)
	}
}
