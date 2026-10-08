import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

struct ManagementTarget: Codable {
	let pid: Int32
	let process_start_identity_decimal: String
	let window_id: Int?
	let bounds: Bounds?
	let is_minimized: Bool?

	init(_ identity: ApplicationProcessIdentity) {
		pid = identity.processIdentifier
		process_start_identity_decimal = String(identity.processStartIdentity)
		window_id = nil
		bounds = nil
		is_minimized = nil
	}

	init?(window: ServiceWindowInfo, pid: Int32) {
		guard let identity = window.mutationIdentity,
			identity.ownerProcessIdentifier == pid,
			identity.windowID == window.windowID,
			identity.capturedBounds == window.bounds
		else { return nil }
		self.pid = pid
		process_start_identity_decimal = String(identity.ownerProcessStartIdentity)
		window_id = identity.windowID
		bounds = Bounds(window.bounds)
		is_minimized = window.isMinimized
	}

	func processIdentity() throws -> ApplicationProcessIdentity {
		guard pid > 0, let generation = UInt64(process_start_identity_decimal), generation > 0,
			String(generation) == process_start_identity_decimal
		else { throw ManagementError("Use the exact application target from desktop inventory.") }
		return ApplicationProcessIdentity(processIdentifier: pid, processStartIdentity: generation)
	}

	func windowIdentity() throws -> WindowMutationIdentity {
		let process = try processIdentity()
		guard let window_id, let id = UInt32(exactly: window_id), id > 0,
			let bounds, let is_minimized,
			[bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
			bounds.width > 0, bounds.height > 0
		else { throw ManagementError("Use the exact window target and original bounds from desktop_windows.") }
		return WindowMutationIdentity(
			windowID: window_id,
			ownerProcessIdentifier: process.processIdentifier,
			ownerProcessStartIdentity: process.processStartIdentity,
			capturedBounds: CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height),
			isMinimized: is_minimized
		)
	}
}

private struct ManagementRequest: Decodable {
	enum Operation: String, Decodable {
		case activate, quit, close, focus, minimize, restore, move, resize
	}
	struct Position: Decodable {
		let x: Double
		let y: Double
	}
	struct Size: Decodable {
		let width: Double
		let height: Double
	}
	let op: Operation
	let target: ManagementTarget
	let position: Position?
	let size: Size?

	func validate() throws {
		switch op {
		case .move:
			guard let position, size == nil, position.x.isFinite, position.y.isFinite else {
				throw ManagementError("Window position must contain finite x and y in desktop logical points.")
			}
		case .resize:
			guard let size, position == nil, size.width.isFinite, size.height.isFinite,
				size.width > 0, size.height > 0
			else { throw ManagementError("Window size must contain positive finite width and height in desktop logical points.") }
		default:
			guard position == nil, size == nil else {
				throw ManagementError("Only move or resize accepts requested window geometry.")
			}
		}
	}
}

private struct ManagementError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

private struct ManagementMessage: Encodable {
	let code: String
	let message: String
	let hint: String?
}

private struct ManagementResult: Encodable {
	var outcome = "refused"
	var action = "management"
	var native_outcome: DesktopActionOutcome?
	var terminated: Bool?
	var message: String?
	var requires_fresh_observation = false
	var error: ManagementMessage?
}

private struct ManagementReply: Encodable {
	let success = true
	let data: ManagementResult
	let target_receipt: Receipt?
}

func nativeManagement(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var result = ManagementResult()
	var receipt: Receipt?
	var invoked = false
	var closing: WindowMutationIdentity?
	do {
		let request = try readManagement()
		result.action = request.op.rawValue
		try request.validate()
		let process = try request.target.processIdentity()
		let window: WindowMutationIdentity?
		if request.op == .activate || request.op == .quit {
			guard request.target.window_id == nil, request.target.bounds == nil, request.target.is_minimized == nil else {
				throw ManagementError("Activation and quit take an application target from desktop_apps.")
			}
			window = nil
		} else {
			window = try request.target.windowIdentity()
		}
		if request.op == .quit {
			guard handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedApplicationQuitVersion,
				handshake.supportedOperations.contains(.quitApplication),
				(handshake.enabledOperations ?? handshake.supportedOperations).contains(.quitApplication)
			else { throw ManagementError("The desktop runtime does not support process-generation-pinned quit. Update the runtime before acting.") }
		}
		// Match Peekaboo's capture preflight; absent session state does not establish a lock.
		let session = CGSessionCopyCurrentDictionary() as NSDictionary?
		if session?["CGSSessionScreenIsLocked"] as? Bool == true {
			throw DesktopActionFailure.preDispatchRefusal(
				reason: .targetUnavailable,
				message: "The macOS GUI session is locked. Desktop management was not dispatched.",
				hint: "Unlock the active user session, then refresh desktop_apps or desktop_windows before choosing a new action."
			)
		}
		// The inventory receipt proves signed transport; optional source-build metadata is not required.
		let inventory = try await client.listApplicationMutationInventory()
		guard let preflight = await client.lastOperationReceipt(), preflight.payload.operation == PeekabooBridgeRequest.listApplicationMutationInventory.operation else {
			throw ManagementError("The native runtime cannot attest exact management targets. Update the desktop runtime before acting.")
		}
		// A failed read-only preflight cannot have dispatched this management action. Native revalidation still owns races.
		guard let application = inventory.items.first(where: { $0.processIdentifier == process.processIdentifier }),
			application.processIdentity == process
		else { throw ManagementError("The observed application generation could not be verified. Refresh desktop_apps before acting.") }
		try Task.checkCancellation()
		let outcome: DesktopActionOutcome?
		let operation: PeekabooBridgeOperation
		var terminated: Bool?
		invoked = true
		switch request.op {
		case .activate:
			operation = .activateApplication
			let action = try await client.activateApplicationTargetedResult(request: .init(
				identifier: "PID:\(process.processIdentifier)", expectedIdentity: process
			))
			result.native_outcome = action.outcome
			guard action.targetIdentity?.processIdentity == process, action.targetIdentity?.exactWindow == nil else {
				throw ManagementError("Activation returned no matching application-only receipt.")
			}
			outcome = action.outcome
		case .quit:
			operation = .quitApplication
			let action = try await client.quitApplicationResult(request: .init(
				identifier: "PID:\(process.processIdentifier)", force: false, expectedIdentity: process
			), supportsPinnedQuit: true)
			terminated = action.payload
			outcome = action.outcome
		case .close:
			operation = .backgroundCloseWindow
			closing = window
			outcome = try await client.closeWindowResult(
				target: .windowId(window!.windowID), expectedIdentity: window!, allowForegroundFallback: false
			).outcome
		case .focus:
			operation = .focusWindow
			let action = try await client.focusWindowResult(target: .windowId(window!.windowID), expectedIdentity: window!)
			result.native_outcome = action.outcome
			guard action.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(as: window!) == true else {
				throw ManagementError("Focus returned no matching exact-window receipt.")
			}
			outcome = action.outcome
		case .minimize:
			operation = .minimizeWindow
			outcome = try await client.minimizeWindowResult(target: .windowId(window!.windowID), expectedIdentity: window!).outcome
		case .restore:
			operation = .restoreWindow
			outcome = try await client.restoreWindowResult(target: .windowId(window!.windowID), expectedIdentity: window!).outcome
		case .move:
			operation = .moveWindow
			let position = request.position!
			outcome = try await client.moveWindowResult(
				target: .windowId(window!.windowID), expectedIdentity: window!,
				to: CGPoint(x: position.x, y: position.y)
			).outcome
		case .resize:
			operation = .resizeWindow
			let size = request.size!
			outcome = try await client.resizeWindowResult(
				target: .windowId(window!.windowID), expectedIdentity: window!,
				to: CGSize(width: size.width, height: size.height)
			).outcome
		}
		result.native_outcome = outcome
		// State and geometry results omit targetIdentity; the client's accepted signed receipt retains it.
		guard let signed = await client.lastOperationReceipt(), signed.payload.operation == operation,
			let outcome, signed.payload.outcome?.outcome == outcome
		else { throw ManagementError("The management action returned without its matching verified operation receipt and outcome.") }
		switch signed.payload.target {
		case let .process(identity) where window == nil && identity == process:
			receipt = Receipt(pid: identity.processIdentifier, window_id: nil, process_start_identity_decimal: String(identity.processStartIdentity))
		case let .window(identity) where window.map({ identity.hasSameStableReceipt(as: $0) }) == true:
			receipt = Receipt(pid: identity.ownerProcessIdentifier, window_id: identity.windowID, process_start_identity_decimal: String(identity.ownerProcessStartIdentity))
		default:
			throw ManagementError("The management action's signed target did not match the original inventory target.")
		}
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		result.terminated = terminated
		if terminated == false {
			result.message = "The normal quit request was accepted, but termination was not confirmed. Inspect remaining windows for unsaved work or other dialogs; do not blindly retry or force quit."
		}
		if request.op == .close, !outcome.isConfirmed {
			result.message = "The close request was not confirmed complete. Inspect remaining windows for unsaved work or other dialogs; do not blindly retry close."
		}
		switch outcome.state {
		case .refused:
			result.outcome = "refused"
		case .indeterminate, .partial:
			result.outcome = "unknown"
		default:
			result.outcome = outcome.evidence == .operationStillRunning || terminated == false || (request.op == .close && !outcome.isConfirmed) ? "unknown" : "completed"
		}
	} catch let failure as DesktopActionFailure {
		result.outcome = failure.outcome.dispatchState.mutationDispatched ? "unknown" : "refused"
		result.native_outcome = failure.outcome
		// The bridge attributes failures only after verifying the signed request-bound target.
		if let closing, failure.targetReceipt == closing.actionTargetReceipt {
			receipt = Receipt(pid: closing.ownerProcessIdentifier, window_id: closing.windowID, process_start_identity_decimal: String(closing.ownerProcessStartIdentity))
		}
		result.requires_fresh_observation = failure.outcome.dispatchState.mutationDispatched || failure.outcome.escalation == .refreshTarget
		result.error = ManagementMessage(code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED", message: failure.message, hint: failure.hint)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.requires_fresh_observation = invoked
		result.error = ManagementMessage(
			code: (error as? PeekabooBridgeErrorEnvelope)?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked ? "Refresh the target before any retry; the action may already have happened." : nil
		)
	}
	return try JSONEncoder().encode(ManagementReply(data: result, target_receipt: receipt))
}

private func readManagement() throws -> ManagementRequest {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		data.append(chunk)
		guard data.count <= 16_384 else { throw ManagementError("The desktop management request exceeds 16 KiB.") }
	}
	return try JSONDecoder().decode(ManagementRequest.self, from: data)
}
