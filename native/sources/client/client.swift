import DesktopToolsIdentity
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

@main
private enum Client {
	static func main() async {
		do {
			write(try await execute(Array(CommandLine.arguments.dropFirst())))
		} catch ClientError.dialect {
			write(try! JSONEncoder().encode(Failure(error: Message(
				code: "DESKTOP_PROTOCOL_MISMATCH", message: ClientError.dialect.localizedDescription
			))))
			exit(1)
		} catch let error as PeekabooBridgeErrorEnvelope {
			write(try! JSONEncoder().encode(Failure(error: error)))
			exit(1)
		} catch {
			write(try! JSONEncoder().encode(Failure(error: Message(
				code: "DESKTOP_ERROR", message: error.localizedDescription
			))))
			exit(1)
		}
	}

	private static func execute(_ args: [String]) async throws -> Data {
		guard args.count >= 2 else { throw ClientError.usage }
		let operation = args[1]
		guard (operation == "apps" && args.count == 2)
			|| (operation == "windows" && args.count == 3)
			|| (operation == "inspect" && (args.count == 5 || args.count == 6))
			|| (operation == "action" && args.count == 2)
			|| (operation == "management" && args.count == 2)
			|| (operation == "launch" && args.count == 2)
			|| (operation == "open" && args.count == 2)
			|| (operation == "clipboard" && args.count == 2)
			|| (operation == "menus" && args.count == 2)
			|| (operation == "menu" && args.count == 2)
		else { throw ClientError.usage }
		let identity = try SigningIdentity.current()
		let client = PeekabooBridgeClient(
			socketPath: args[0],
			maxResponseBytes: 48 * 1024 * 1024,
			requestTimeoutSec: 25,
			trustedHostTeamIDs: [identity.team]
		)
		let handshake = try await client.handshake(
			client: .init(
				bundleIdentifier: identity.identifier,
				teamIdentifier: identity.team,
				processIdentifier: getpid()
			),
			requestedHost: .gui,
			overallTimeoutSec: 5
		)
		// Patched operations reuse Peekaboo's protocol version; refuse other hosts before any request.
		guard handshake.hostCapabilities?.contains(desktopToolsProtocol) == true else { throw ClientError.dialect }
		switch operation {
		case "action":
			return try await nativeAction(client)
		case "clipboard":
			return try await nativeClipboard(client)
		case "menu":
			return try await nativeMenuCommand(client, handshake: handshake)
		case "menus":
			return try await nativeMenus(client)
		case "management":
			return try await nativeManagement(client, handshake: handshake)
		case "launch":
			return try await nativeLaunch(client, handshake: handshake)
		case "open":
			return try await nativeLaunch(client, handshake: handshake, opensItem: true)
		case "apps":
			let inventory = try await client.listApplicationMutationInventory()
			var metadata: [ServiceApplicationInfo] = []
			var warnings: [String] = []
			do {
				metadata = try await client.listApplications()
			} catch {
				try Task.checkCancellation()
				warnings.append("Application presentation metadata was unavailable; activity and visibility are unknown.")
			}
			let grouped = Dictionary(grouping: metadata, by: \.processIdentifier)
			var matched: [Int32: ServiceApplicationInfo] = [:]
			for app in inventory.items {
				guard let generation = app.processStartIdentity, generation > 0 else { continue }
				let candidates = (grouped[app.processIdentifier] ?? []).filter { $0.processStartIdentity == generation }
				if candidates.count == 1 { matched[app.processIdentifier] = candidates[0] }
			}
			let active = metadata.filter(\.isActive)
			let activityKnown = active.count == 1
				&& active[0].processStartIdentity != nil
				&& matched[active[0].processIdentifier]?.processStartIdentity == active[0].processStartIdentity
			if !activityKnown {
				warnings.append("No unique active application with matching process-generation identity was observed; activity is unknown.")
			}
			if matched.count < inventory.items.count {
				warnings.append("Some applications lacked presentation metadata matching their process generation; their activity and visibility are unknown.")
			}
			return try encode(Apps(
				apps: inventory.items.map { App($0, metadata: matched[$0.processIdentifier], activityKnown: activityKnown) },
				inventory_completeness: inventory.completeness.rawValue,
				inventory_warnings: inventory.warnings,
				metadata_warnings: warnings
			))
		case "windows":
			let pid = try processID(args[2])
			let inventory = try await client.listWindowMutationInventory(target: .application("PID:\(pid)"))
			return try encode(Windows(
				pid: pid,
				windows: inventory.items.map { Window($0, pid: pid) },
				inventory_completeness: inventory.completeness.rawValue,
				inventory_warnings: inventory.warnings
			))
		default:
			let pid = try processID(args[2])
			guard let window = UInt32(args[3]), window > 0 else { throw ClientError.usage }
			guard args[4].hasPrefix("/") else { throw ClientError.usage }
			guard let mode = InspectionMode(rawValue: args.count == 6 ? args[5] : "accessibility")
			else { throw ClientError.usage }
			return try await inspect(client, pid: pid, window: window, path: args[4], mode: mode)
		}
	}

	private static func inspect(
		_ client: PeekabooBridgeClient, pid: Int32, window: UInt32, path: String, mode: InspectionMode
	) async throws -> Data {
		guard mode == .pixels else { return try await observe(client, pid: pid, window: window, path: path, pixels: nil) }
		// Screenshot-only results have no detection ID, so the request pins its publication explicitly.
		let snapshot = try await client.createSnapshot()
		do {
			return try await observe(client, pid: pid, window: window, path: path, pixels: snapshot)
		} catch {
			try? await client.cleanSnapshot(snapshotId: snapshot)
			throw error
		}
	}

	private static func observe(
		_ client: PeekabooBridgeClient, pid: Int32, window: UInt32, path: String, pixels: String?
	) async throws -> Data {
		let accessibility = pixels == nil
		let observation = try await client.desktopObservationWithOutcome(.init(
			target: .pid(pid, window: .id(window)),
			capture: .init(scale: .logical1x, focus: .background),
			detection: .init(
				mode: accessibility ? .accessibility : .none,
				traversalBudget: .init(maxDepth: 15, maxElementCount: 200, maxChildrenPerNode: 100),
				requiresFreshAccessibilityTree: accessibility
			),
			output: .init(path: path, saveSnapshot: true, snapshotID: pixels, includeImageData: true),
			timeout: .init(overall: 20, detection: 15)
		))
		guard let target = observation.targetIdentity,
			target.processIdentity.processIdentifier == pid,
			let exact = target.exactWindow, exact.identity.windowID == Int(window)
		else { throw ClientError.target }
		let result = observation.payload
		if let pixels {
			guard result.files.publishedSnapshotID == pixels, result.elements == nil else { throw ClientError.pixels }
			// Expose the ID only after the stored canonical projection grants pointer authority for this exact capture.
			let detection = try await client.getDetectionResult(snapshotId: pixels)
			let (context, identity, bounds) = try snapshotWindow(detection)
			let authority = try coordinateAuthority(
				pixels, detection, window: .init(identity: identity, bounds: bounds)
			)
			guard detection.snapshotId == pixels, detection.elements.all.isEmpty, context.focusedElement == nil,
				identity.hasSameStableReceipt(as: exact.identity), bounds == exact.bounds,
				authority.context == CaptureCoordinateContext(metadata: result.capture.metadata, referenceID: pixels)
			else { throw ClientError.pixels }
		}
		let image = try result.verifiedCaptureImageData(requirement: .requireDigest)
		guard !image.isEmpty, image.count <= 32 * 1024 * 1024 else { throw ClientError.image }
		// Reusable snapshots keep Bridge-owned artifact copies; the host removes this caller-visible file after resizing.
		try image.write(to: URL(fileURLWithPath: path), options: [.atomic])
		let data = Inspection(
			inspection_mode: accessibility ? InspectionMode.accessibility.rawValue : InspectionMode.pixels.rawValue,
			note: accessibility ? nil : "Pixel snapshot: no Accessibility elements or focused control. Its snapshot_id authorizes only screenshot-point clicks, point scrolls, and drags in this exact window; element, text, key, and insertion actions are refused.",
			application_name: result.target.app?.name,
			window_title: result.target.window?.title,
			snapshot_id: result.files.publishedSnapshotID,
			element_count: result.elements?.metadata.elementCount ?? 0,
			ui_elements: result.elements?.elements.all.map(Element.init) ?? [],
			coordinate_context: result.elements?.metadata.captureCoordinateContext
				?? CaptureCoordinateContext(metadata: result.capture.metadata),
			capture_warning: result.capture.warning,
			detection_metadata: result.elements?.metadata,
			diagnostics: result.diagnostics,
			timings: result.timings
		)
		return try encode(data, receipt: .init(
			pid: pid,
			window_id: Int(window),
			process_start_identity_decimal: String(target.processIdentity.processStartIdentity)
		))
	}

	private static func processID(_ value: String) throws -> Int32 {
		guard let pid = Int32(value), pid > 0 else { throw ClientError.usage }
		return pid
	}

	private static func encode<T: Encodable>(_ data: T, receipt: Receipt? = nil) throws -> Data {
		try JSONEncoder().encode(Success(data: data, target_receipt: receipt))
	}

	private static func write(_ data: Data) {
		FileHandle.standardOutput.write(data)
		FileHandle.standardOutput.write(Data([10]))
	}
}

private struct Success<T: Encodable>: Encodable {
	let success = true
	let data: T
	let target_receipt: Receipt?
}

private struct Failure<T: Encodable>: Encodable {
	let success = false
	let error: T
}

private struct Message: Encodable {
	let code: String
	let message: String
}

struct Receipt: Encodable {
	let pid: Int32
	let window_id: Int?
	let process_start_identity_decimal: String
}

private struct Apps: Encodable {
	let apps: [App]
	let inventory_completeness: String
	let inventory_warnings: [String]
	let metadata_warnings: [String]
}

private struct App: Encodable {
	let name: String
	let pid: Int32
	let bundle_id: String?
	let is_active: Bool?
	let is_active_known: Bool
	let is_hidden: Bool?
	let is_hidden_known: Bool
	let process_start_identity_decimal: String?
	let warnings: [String]?
	let target: ManagementTarget?

	init(_ app: ServiceApplicationInfo, metadata: ServiceApplicationInfo?, activityKnown: Bool) {
		name = app.name
		pid = app.processIdentifier
		bundle_id = app.bundleIdentifier
		// Mutation inventory supplies identity, not presentation state. Missing reads must stay unknown.
		is_active_known = metadata != nil && activityKnown
		is_active = is_active_known ? metadata?.isActive : nil
		is_hidden_known = metadata?.isHiddenKnown == true
		is_hidden = is_hidden_known ? metadata?.isHidden : nil
		process_start_identity_decimal = app.processStartIdentity.map(String.init)
		let combined = (app.metadataWarnings ?? []) + (metadata?.metadataWarnings ?? [])
		warnings = combined.isEmpty ? nil : Array(Set(combined)).sorted()
		target = app.processIdentity.map(ManagementTarget.init)
	}
}

private struct Windows: Encodable {
	let pid: Int32
	let windows: [Window]
	let inventory_completeness: String
	let inventory_warnings: [String]
}

private struct Window: Encodable {
	let window_id: Int
	let window_title: String
	let bounds: Bounds
	let is_on_screen: Bool
	let is_minimized: Bool
	let is_key: Bool?
	let observation_capability: String?
	let observation_reason: String?
	let process_start_identity_decimal: String?
	let target: ManagementTarget?

	init(_ window: ServiceWindowInfo, pid: Int32) {
		window_id = window.windowID
		window_title = window.title
		bounds = Bounds(window.bounds)
		is_on_screen = window.isOnScreen
		is_minimized = window.isMinimized
		is_key = window.isKeyWindow
		observation_capability = window.observationCapability?.mode.rawValue
		observation_reason = window.observationCapability?.reason?.rawValue
		process_start_identity_decimal = window.mutationIdentity.map { String($0.processIdentity.processStartIdentity) }
		target = ManagementTarget(window: window, pid: pid)
	}
}

struct Bounds: Codable {
	let x: Double
	let y: Double
	let width: Double
	let height: Double

	init(_ rectangle: CGRect) {
		x = rectangle.origin.x
		y = rectangle.origin.y
		width = rectangle.width
		height = rectangle.height
	}
}

private struct Inspection: Encodable {
	let inspection_mode: String
	let note: String?
	let application_name: String?
	let window_title: String?
	let snapshot_id: String?
	let element_count: Int
	let ui_elements: [Element]
	let coordinate_context: CaptureCoordinateContext
	let capture_warning: String?
	let detection_metadata: DetectionMetadata?
	let diagnostics: DesktopObservationDiagnostics
	let timings: ObservationTimings
}

private struct Element: Encodable {
	let id: String
	let role: String
	let label: String?
	let value: String?
	let bounds: Bounds
	let is_enabled: Bool
	let is_selected: Bool?
	let attributes: [String: String]

	init(_ element: DetectedElement) {
		id = element.id
		role = element.type.rawValue
		label = element.label
		value = element.value
		bounds = Bounds(element.bounds)
		is_enabled = element.isEnabled
		is_selected = element.isSelected
		attributes = element.attributes
	}
}

private enum InspectionMode: String {
	case accessibility, pixels
}

private enum ClientError: LocalizedError {
	case usage, target, image, pixels, dialect

	var errorDescription: String? {
		switch self {
		case .usage:
			"Usage: desktop-tools-client <socket> apps | windows <pid> | inspect <pid> <window> <absolute-output-path> [accessibility|pixels] | menus|menu|action|management|launch|open|clipboard < JSON"
		case .target:
			"The native observation did not confirm the requested process and window. Refresh the window list and try again."
		case .image:
			"The native observation returned an empty or oversized screenshot."
		case .pixels:
			"The native pixel observation did not publish a screenshot-only snapshot with exact-window coordinate authority."
		case .dialect:
			"The desktop host does not serve the \(desktopToolsProtocol) operations. No request was sent; use the client built with that host"
		}
	}
}
