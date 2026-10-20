import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// What an embedding runtime, such as libDesktopTools, watches and draws: the activity list, the window outline,
/// the agent cursor, and who may fill a password. Each hook is a no-op until set, never changes a result, and is set
/// once before the server starts.
public enum Hooks {
	/// Called once per tool call after it finishes, while the client still waits for its reply, so the client's
	/// environment and parent are still readable.
	nonisolated(unsafe) public static var operation: (@Sendable (Operation) -> Void)?

	/// Called before dispatch, once the call is admitted, with the one exact window it observes or acts on.
	nonisolated(unsafe) public static var targetWindow: (@Sendable (TargetWindow) -> Void)?

	/// Shows pointer input before it is posted; the input waits until it returns or `pointerLimit` passes. Delivery
	/// calls `showPointer` once per input, after its window check and before its first event: desktop_press shows
	/// `.hold` before pressing, and its release, however the hold ends, a single `.click` at the same point.
	nonisolated(unsafe) public static var pointer: (@Sendable (PointerFeedback) async -> Void)?

	/// Decides each secure text field fill, as Peekaboo's handleSecureTextFill (MIT) asked its embedder.
	/// desktop_fill_password calls it from its delivery, after the snapshot and window checks, refusing first:
	/// with `noSecureTextFill` (operation_unsupported) when it is nil; a target in SecurityAgent, LocalAuthentication,
	/// loginwindow or coreautha with the system prompt refusal; and a focused element that isn't secure. It then
	/// awaits the hook with the client (`Hooks.call?.client`), the target pid, app name, bundle ID, the field's web
	/// host and the secret; `.refuse(message)` refuses with that message (permission_denied) and `.fill(secret)`
	/// goes on to Peekaboo's checks: no empty or control-character secret, focus unchanged since the hook was
	/// asked, then typing. It must never log, return or keep the secret.
	nonisolated(unsafe) public static var secureTextFill: (@Sendable (SecureTextFillContext) async -> SecureTextFillAuthorization)?

	/// Peekaboo's agentCursorFeedbackLimit: input never waits longer than this for its feedback.
	public static let pointerLimit = DispatchTimeInterval.milliseconds(600)

	/// The refusal desktop_fill_password gives when no hook decides fills, as Peekaboo's Bridge gives it.
	public static let noSecureTextFill = "This host does not fill secure text fields."

	public struct Operation: Sendable {
		public enum Outcome: String, Sendable {
			case completed, refused, unknown, error
		}

		public let tool: String
		/// The call's arguments, only to tell a tool's routes apart, such as desktop_dock's click and menu; their
		/// values, such as typed text, are never to be recorded.
		public let arguments: JSON
		/// The connected MCP binary.
		public let client: pid_t
		/// completed only when the effect was confirmed or the call changes nothing; input that was sent but not
		/// read back is unknown, as the Bridge reported it.
		public let outcome: Outcome
		public let mutatesDesktop: Bool
		public let targetProcess: pid_t?
		public let targetWindow: CGWindowID?
	}

	public struct TargetWindow: Sendable {
		public let client: pid_t
		public let process: pid_t
		public let window: CGWindowID
	}

	/// Global Core Graphics points: top-left origin on the primary display. `window` is the exact window the input
	/// goes to.
	public enum PointerFeedback: Sendable {
		case click(at: CGPoint, kind: ClickKind, window: Int)
		/// A held button, which lasts until a `.click` of kind single at the same point releases it.
		case hold(at: CGPoint, window: Int)
		case scroll(at: CGPoint, direction: ScrollDirection, amount: Int, window: Int)
		case drag(from: CGPoint, to: CGPoint, seconds: Double, window: Int)
		case move(to: CGPoint, window: Int)
	}

	/// A Keychain password item, by its attributes.
	public struct KeychainItem: Sendable, Equatable {
		public enum Kind: String, Sendable {
			/// `kSecClassGenericPassword`, named by its service.
			case generic
			/// `kSecClassInternetPassword`, named by its server; it fills only a web field on that host.
			case internet
		}

		public let kind: Kind
		public let name: String
		public let account: String?

		public init(kind: Kind, name: String, account: String?) {
			self.kind = kind
			self.name = name
			self.account = account
		}
	}

	/// What the hook is asked to authorize for one fill, as Peekaboo's PeekabooBridgeSecureTextFillContext (MIT).
	public struct SecureTextFillContext: Sendable {
		public enum Secret: Sendable {
			/// A Keychain item the hook reads, so the agent never sees the secret.
			case keychain(KeychainItem)
			/// Text the agent sent, which the hook may use only once it is allowed.
			case text(String)
		}

		public let client: pid_t
		public let targetProcess: pid_t
		public let applicationName: String?
		public let bundleIdentifier: String?
		/// The host of the field's web page, when it is in a web area whose URL has one.
		public let webHost: String?
		public let secret: Secret

		public init(client: pid_t, targetProcess: pid_t, applicationName: String?, bundleIdentifier: String?, webHost: String?, secret: Secret) {
			self.client = client
			self.targetProcess = targetProcess
			self.applicationName = applicationName
			self.bundleIdentifier = bundleIdentifier
			self.webHost = webHost
			self.secret = secret
		}
	}

	public enum SecureTextFillAuthorization: Sendable {
		/// Type this secret.
		case fill(String)
		/// Refuse before any input, with this message.
		case refuse(String)
	}

	/// The call running on this task: its client and the window it names, read before dispatch.
	public struct Call: Sendable {
		public let client: pid_t
		public let process: pid_t?
		public let window: Int?
	}

	@TaskLocal public static var call: Call?

	/// Reports the running call's window to `targetWindow`; Tools.call calls it once admission passes.
	static func admitted() {
		guard let targetWindow, let call, let process = call.process, let window = call.window.flatMap(CGWindowID.init(exactly:))
		else { return }
		targetWindow(TargetWindow(client: call.client, process: process, window: window))
	}

	/// Shows `feedback` from a delivery thread, which waits for it at most `pointerLimit`; a late one plays on alone.
	public static func showPointer(_ feedback: PointerFeedback) {
		guard let pointer else { return }
		let done = DispatchSemaphore(value: 0)
		Task {
			await pointer(feedback)
			done.signal()
		}
		_ = done.wait(timeout: .now() + pointerLimit)
	}

	/// The process and exact window a call names, directly or through its snapshot.
	static func target(_ arguments: JSON) async -> (process: pid_t?, window: Int?) {
		if let id = arguments["snapshot"]?.string, let snapshot = await Snapshots.shared.get(id) {
			return (snapshot.pid, snapshot.windowID)
		}
		let pid = (arguments["pid"]?.int ?? arguments["target"]?["pid"]?.int).flatMap(pid_t.init(exactly:))
		let window = arguments["window"]?.int ?? arguments["target"]?["window_id"]?.int
		return (pid, pid == nil ? nil : window)
	}

	/// The Bridge's recorded outcome: input sent but not read back is unknown even when the tool says completed.
	static func outcome(_ result: ToolResult) -> Operation.Outcome {
		switch result.outcome {
		case "refused"?: return .refused
		case "unknown"?: return .unknown
		case "completed"?:
			let state = (try? JSON(parsing: result.text))?["action"]?["native_outcome"]?["state"]?.string
			return [nil, "confirmed_change", "confirmed_no_change"].contains(state) ? .completed : .unknown
		case _?: return .unknown
		case nil: return result.isError ? .error : .completed
		}
	}
}

extension Tools {
	/// One call as the server runs it, reported to the hooks.
	static func observed(_ name: String, arguments: JSON, client: pid_t) async -> ToolResult {
		// Read before dispatch, and only when watched: an action spends its snapshot.
		let watched = Hooks.operation != nil || Hooks.targetWindow != nil
		let target = watched ? await Hooks.target(arguments) : (process: nil, window: nil)
		let result = await Hooks.$call.withValue(Hooks.Call(client: client, process: target.process, window: target.window)) {
			await call(name, arguments: arguments, client: client)
		}
		guard watched else { return result }
		Hooks.operation?(Hooks.Operation(
			tool: name, arguments: arguments, client: client, outcome: Hooks.outcome(result),
			mutatesDesktop: Contract.actions.contains(name), targetProcess: target.process,
			targetWindow: target.window.flatMap(CGWindowID.init(exactly:))))
		return result
	}
}
