import DesktopToolsIdentity
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

private struct Status: Encodable {
	var state = "stopped"
	var error: String?
	var accessibility = false
	var screenRecording = false
	var eventSynthesizing = false
	var clipboardRead = ClipboardPolicy()
	var cursor = false
	var highlight = false
	var paused = false
}

private final class State: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Status()

	func set(_ phase: String, error: String? = nil) {
		lock.lock()
		defer { lock.unlock() }
		value.state = phase
		value.error = error
	}

	func read() -> Status {
		lock.lock()
		var result = value
		lock.unlock()
		result.accessibility = AXIsProcessTrusted()
		result.screenRecording = CGPreflightScreenCaptureAccess()
		result.eventSynthesizing = result.eventSynthesizing || CGPreflightPostEventAccess()
		result.clipboardRead = ClipboardPolicy.current()
		result.paused = Pause.shared.isPaused
		return result
	}

	func setCursor(_ enabled: Bool) {
		lock.lock()
		value.cursor = enabled
		lock.unlock()
	}

	func setHighlight(_ enabled: Bool) {
		lock.lock()
		value.highlight = enabled
		lock.unlock()
	}

	func recordEventSynthesizing(_ granted: Bool) {
		lock.lock()
		value.eventSynthesizing = value.eventSynthesizing || granted
		lock.unlock()
	}
}

private let state = State()

@MainActor
private final class Desktop {
	static let shared = Desktop()
	private var runtime: PeekabooEmbeddedBridgeRuntime?
	private var tail: Task<Void, Never>?

	func start(socket: String, client: String) {
		let previous = tail
		tail = Task {
			await previous?.value
			if let runtime { await runtime.stopChecked() }
			runtime = nil
			state.set("starting")
			do {
				let identity = try SigningIdentity.current()
				var configuration = PeekabooEmbeddedBridgeRuntime.Configuration(
					socketPath: socket,
					allowlistedTeams: [identity.team],
					allowlistedBundles: [client],
					allowedOperations: [
						.listApplications, .getFocusedElement, .listWindows, .listMenus, .menuCommand, .desktopObservation, .inspectAccessibilityTree,
						.createSnapshot, .cleanSnapshot, .ownsSnapshot, .getDetectionResult, .beginSnapshotMutation,
						.finishSnapshotMutation,
						.targetedClick, .exactWindowTargetedClick, .foregroundModifierClick, .setValue, .performAction, .exactWindowTargetedHotkey, .hotkey, .exactWindowTargetedTypeActions,
						.selectText, .literalInsert, .attachmentInsert, .clipboardTextRead, .clipboardImageRead, .clipboardImageExport, .clipboardFilesRead, .clipboardTextWrite, .clipboardImageWrite, .clipboardFilesWrite, .targetedScroll, .exactWindowDrag, .drag, .moveMouse, .systemDefinedKey, .selectInputSource,
						.createExactWindowHeldPointerOwner, .beginExactWindowHeldPointer, .releaseExactWindowHeldPointer,
						.revokeExactWindowHeldPointer, .disconnectExactWindowHeldPointerOwner,
						.launchApplicationWithOptions, .activateApplication, .quitApplication, .hideApplication, .backgroundCloseWindow,
						.focusWindow, .minimizeWindow, .restoreWindow, .maximizeWindow, .setWindowFullScreen,
						.moveWindow, .resizeWindow,
						.targetedDialogListElements, .prepareDialogAction, .exactDialogClickButton, .exactDialogEnterText, .exactFileDialogPath,
						.listMenuBarItems, .clickMenuBarItemIndex, .listDockItems, .launchDockItem, .rightClickDockItem,
					],
					hostKind: .gui,
					hostCapabilities: [PeekabooBridgeHostCapability.backgroundBridgeHost, desktopToolsProtocol],
					requestTimeoutSeconds: 25
				)
				configuration.targetWindowObserver = { target in
					// The requesting client is still waiting for its reply, so its environment is readable now.
					let agent = agentName(of: target.clientProcessIdentifier)
					DispatchQueue.main.async {
						AgentWindow.shared.target(window: target.windowID, process: target.processIdentifier, agent: agent)
					}
				}
				configuration.operationObserver = recordActivity
				configuration.operationAdmission = { operation, mutatesDesktop in
					Pause.shared.refusal(operation, mutatesDesktop: mutatesDesktop)
				}
				let next = PeekabooEmbeddedBridgeRuntime.make(configuration: configuration, feedbackClient: AgentCursor.shared)
				runtime = next
				try await next.startChecked()
				state.set("ready")
			} catch {
				if let runtime { await runtime.stopChecked() }
				runtime = nil
				state.set("error", error: error.localizedDescription)
			}
		}
	}

	func stop() {
		let previous = tail
		tail = Task {
			await previous?.value
			state.set("stopping")
			if let runtime { await runtime.stopChecked() }
			runtime = nil
			state.set("stopped")
		}
	}
}

/// Starts the Bridge on `socket` for the exact signed `client` identifier from this process's team.
@_cdecl("desktop_tools_start")
public func start(_ socket: UnsafePointer<CChar>, _ client: UnsafePointer<CChar>) {
	let socket = String(cString: socket)
	let client = String(cString: client)
	state.set("starting")
	// Bun's thread must not wait for work that needs the application's main run loop.
	DispatchQueue.main.async {
		Desktop.shared.start(socket: socket, client: client)
	}
}

/// Returns status JSON; release it with `desktop_tools_free`.
@_cdecl("desktop_tools_status")
public func status() -> UnsafeMutablePointer<CChar>? {
	let data = try! JSONEncoder().encode(state.read())
	return strdup(String(decoding: data, as: UTF8.self))
}

/// Stops the Bridge after outstanding native operations drain; poll status until `stopped`.
@_cdecl("desktop_tools_stop")
public func stop() {
	state.set("stopping")
	DispatchQueue.main.async { Desktop.shared.stop() }
}

/// Shows or hides the agent cursor drawn for pointer input; it is off until an embedding app turns it on.
@_cdecl("desktop_tools_set_cursor")
public func setCursor(_ enabled: Bool) {
	state.setCursor(enabled)
	DispatchQueue.main.async { AgentCursor.shared.enabled = enabled }
}

/// Shows or hides the outline and label on the window the agent is using; it is off until an embedding app turns it on.
@_cdecl("desktop_tools_set_highlight")
public func setHighlight(_ enabled: Bool) {
	state.setHighlight(enabled)
	DispatchQueue.main.async { AgentWindow.shared.enabled = enabled }
}

/// Pauses or resumes all input: while paused, every operation that changes the desktop, and clipboard writes,
/// are refused before dispatch, and reads keep working. Only the embedding app calls this; it starts resumed.
@_cdecl("desktop_tools_set_paused")
public func setPaused(_ paused: Bool) {
	Pause.shared.set(paused)
}

/// Returns the recent operations as a JSON array, newest first; release it with `desktop_tools_free`.
/// They are kept in memory only and never include typed text, clipboard contents or values.
@_cdecl("desktop_tools_activity")
public func activity() -> UnsafeMutablePointer<CChar>? {
	let data = try! JSONEncoder().encode(Activity.shared.read())
	return strdup(String(decoding: data, as: UTF8.self))
}

@_cdecl("desktop_tools_free")
public func release(_ value: UnsafeMutableRawPointer?) {
	free(value)
}

/// Requests `accessibility`, `screenRecording`, or `eventSynthesizing` for this process.
@_cdecl("desktop_tools_permission")
public func permission(_ kind: UnsafePointer<CChar>) {
	let kind = String(cString: kind)
	DispatchQueue.main.async {
		switch kind {
		case "accessibility":
			// The C SDK exposes this immutable option key as an unisolated mutable global.
			let options = ["AXTrustedCheckOptionPrompt": true]
			_ = AXIsProcessTrustedWithOptions(options as CFDictionary)
		case "screenRecording":
			_ = CGRequestScreenCaptureAccess()
		case "eventSynthesizing":
			// macOS caches preflight results; retain an interactive grant in Peekaboo's shared permission state too.
			state.recordEventSynthesizing(PermissionsService().requestPostEventPermission())
		default:
			break
		}
	}
}

private struct ClipboardPolicy: Encodable {
	var policy = "unknown"
	var readAdmitted = false
	var policyAvailable = false

	static func current() -> ClipboardPolicy {
		guard #available(macOS 15.4, *) else {
			return .init(policy: "unavailable_on_this_os", readAdmitted: true, policyAvailable: false)
		}
		let policy: String
		switch NSPasteboard.general.accessBehavior {
		case .default: policy = "default"
		case .ask: policy = "ask"
		case .alwaysAllow: policy = "always_allow"
		case .alwaysDeny: policy = "always_deny"
		@unknown default: policy = "unknown"
		}
		return .init(policy: policy, readAdmitted: policy == "always_allow", policyAvailable: true)
	}
}
