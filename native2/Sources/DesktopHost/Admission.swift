import AppKit
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation
import Security

// Ported from native/Sources/runtime's callers.swift and activity.swift: who may call, and what the user's pause and
// Desktop Tools' own UI keep from running. Every refusal comes before dispatch, so nothing was sent.

/// Who runs each client, and what the user decided for them. Callers are refused only once the embedding app
/// registers a handler to ask the user; until then every caller is served.
public final class Callers: @unchecked Sendable {
	public static let shared = Callers()
	private let lock = NSLock()
	private var handler: (@Sendable (Caller) -> Void)?
	private var decisions: [String: Bool] = [:]
	/// Callers the app was already asked about and hasn't answered for yet.
	private var asked: Set<String> = []
	/// Each caller launch is identified once, so its signature is checked once per launch.
	private var resolved: [String: Caller] = [:]

	public var enforcing: Bool { lock.withLock { handler != nil } }
	/// Whether the app was asked about a caller the user hasn't answered yet. Its prompt goes up asynchronously, so
	/// this covers the moment before the prompt's window is on screen, where the window check can't see it.
	var asking: Bool { lock.withLock { !asked.isEmpty } }

	public func setHandler(_ handler: (@Sendable (Caller) -> Void)?) {
		lock.withLock { self.handler = handler }
	}

	/// The user's answers so far; an answered caller is never asked about again.
	public func setDecisions(_ list: [CallerDecision]) {
		lock.withLock {
			decisions = Dictionary(list.map { ($0.caller.key, $0.allowed) }, uniquingKeysWith: { _, last in last })
			asked.subtract(decisions.keys)
		}
	}

	/// The refusal for a request from `client`, or nil when its caller is approved. An unknown caller is refused
	/// at once and the app is asked about it once; the client never waits for the user.
	func refusal(client: pid_t?) -> String? {
		guard enforcing else { return nil }
		guard let client, let caller = resolve(client: client)?.caller else { return CallerRefusal.unidentified }
		let (decision, ask): (Bool?, (@Sendable (Caller) -> Void)?) = lock.withLock {
			let decision = decisions[caller.key]
			return (decision, decision == nil && asked.insert(caller.key).inserted ? handler : nil)
		}
		switch decision {
		case true?: return nil
		case false?: return CallerRefusal.denied(caller.name)
		case nil:
			ask?(caller)
			return CallerRefusal.waiting(caller.name)
		}
	}

	/// The verified caller of the client `client` and its pid: the nearest ancestor that isn't a launcher or shell.
	public func resolve(client: pid_t) -> (caller: Caller, pid: pid_t)? {
		var chain: [(pid: pid_t, path: String)] = []
		var next = parentProcess(of: client)
		while let process = next, chain.count < 32, let path = executablePath(process) {
			chain.append((process, path))
			next = parentProcess(of: process)
		}
		guard let index = CallerChain.callerIndex(chain.map(\.path)) else { return nil }
		let (process, path) = chain[index]
		guard let start = Mac.generation(process) else { return nil }
		let launch = "\(process) \(start)"
		if let cached = lock.withLock({ resolved[launch] }) { return (cached, process) }
		let caller = identify(process, path: path)
		// The pid could have been reused while its signature was read.
		guard Mac.generation(process) == start else { return nil }
		lock.withLock {
			if resolved.count >= 64 { resolved.removeAll() }
			resolved[launch] = caller
		}
		return (caller, process)
	}
}

/// Pause all input: while on, every tool that changes the desktop, and clipboard writes, is refused before dispatch.
/// Only the embedding app sets it, from its own menu; clients have no way to change it.
public final class Pause: @unchecked Sendable {
	public static let shared = Pause()
	static let message = "Input is paused in Desktop Tools, so nothing was sent. Ask the user to resume input from the Desktop Tools menu; reading the desktop still works."
	private let lock = NSLock()
	private var paused = false

	public var isPaused: Bool { lock.withLock { paused } }
	public func set(_ value: Bool) { lock.withLock { paused = value } }
}

/// Desktop Tools' own processes, by the host's bundle ID, so a dev build and the installed app protect each other.
enum OwnUI {
	static let host = Bundle.main.bundleIdentifier ?? ""

	static func isOwn(_ process: pid_t) -> Bool {
		process == getpid()
			|| OwnUIGuard.isOwn(bundleIdentifier: NSRunningApplication(processIdentifier: process)?.bundleIdentifier, host: host)
	}

	/// Whether any of them shows a prompt or an open menu.
	static func promptOrMenuOpen() -> Bool {
		var own: Set<pid_t> = [getpid()]
		for app in NSWorkspace.shared.runningApplications where OwnUIGuard.isOwn(bundleIdentifier: app.bundleIdentifier, host: host) {
			own.insert(app.processIdentifier)
		}
		guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
		return rows.contains { row in
			guard let owner = row[kCGWindowOwnerPID as String] as? Int32, own.contains(owner) else { return false }
			return OwnUIGuard.isPromptOrMenu(
				layer: row[kCGWindowLayer as String] as? Int ?? 0,
				sharingState: row[kCGWindowSharingState as String] as? Int ?? 1,
				onScreen: true)
		}
	}
}

extension Tools {
	/// The refusal for one call from `client`, or nil when it may run: an unapproved caller first, then input that
	/// could reach Desktop Tools' own UI, then the user's pause. Observing is never paused.
	static func admission(_ name: String, arguments: JSON, client: pid_t?) async -> String? {
		if let refusal = Callers.shared.refusal(client: client) { return refusal }
		guard Contract.actions.contains(name) else { return nil }
		// Clipboard writes can't reach a prompt or menu, so only the pause holds them.
		if name != "desktop_clipboard_write", Callers.shared.enforcing {
			let target = await targetProcess(arguments)
			let ownUIOpen = Callers.shared.asking || OwnUI.promptOrMenuOpen()
			if let refusal = OwnUIGuard.refusal(input: true, targetIsOwn: target.map(OwnUI.isOwn) ?? false, ownUIOpen: ownUIOpen) {
				return refusal
			}
		}
		return Pause.shared.isPaused ? Pause.message : nil
	}

	/// The process a call names, directly or through its snapshot.
	private static func targetProcess(_ arguments: JSON) async -> pid_t? {
		if let pid = arguments["pid"]?.int ?? arguments["target"]?["pid"]?.int { return pid_t(pid) }
		if let id = arguments["snapshot"]?.string { return await Snapshots.shared.get(id)?.pid }
		return nil
	}

	/// What an agent gets for a refusal: actions report a refused action, everything else an error.
	static func refused(_ name: String, _ refusal: String) -> ToolResult {
		guard Contract.actions.contains(name) else { return ToolResult(text: refusal, isError: true) }
		let action: JSON = .object([
			("outcome", "refused"), ("reason", JSON(refusal)), ("message", "The desktop action was not sent to the native desktop."),
		])
		return ToolResult(text: JSON.object([("action", action)]).text, outcome: "refused", isError: true)
	}
}

/// Names and keys the caller from its running code's signature, trusting it only when it validates.
private func identify(_ process: pid_t, path: String) -> Caller {
	var team: String?
	var identifier: String?
	var signer: String?
	var code: SecCode?
	if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process] as CFDictionary, [], &code) == errSecSuccess,
	   let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess
	{
		var staticCode: SecStaticCode?
		var information: CFDictionary?
		if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
		   SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
		   let values = information as? [String: Any]
		{
			identifier = values[kSecCodeInfoIdentifier as String] as? String
			team = (values[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
			if team != nil, let leaf = (values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first {
				signer = organization(leaf)
			} else if satisfies(code, "anchor apple") {
				signer = "Apple"
			}
		}
	}
	return Caller(name: displayName(path, team: team, identifier: identifier), path: path, team: team, identifier: identifier, signer: signer)
}

/// "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)" becomes "Anthropic PBC".
private func organization(_ certificate: SecCertificate) -> String? {
	guard var summary = SecCertificateCopySubjectSummary(certificate) as String? else { return nil }
	if let colon = summary.range(of: ": ") { summary = String(summary[colon.upperBound...]) }
	if let team = summary.range(of: " (", options: .backwards), summary.hasSuffix(")") {
		summary = String(summary[..<team.lowerBound])
	}
	return summary.isEmpty ? nil : summary
}

private func satisfies(_ code: SecCode, _ text: String) -> Bool {
	var requirement: SecRequirement?
	guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
	return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

/// An app's own name, also for a helper inside it. Otherwise, never the process's self-chosen argv[0]: the name in
/// its validated signature, so Claude Code is `claude-code` rather than its versioned file's name.
private func displayName(_ path: String, team: String?, identifier: String?) -> String {
	if let app = CallerChain.appBundle(of: path) {
		let info = Bundle(path: app)?.infoDictionary
		let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
		return name ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
	}
	return CallerChain.signedName(team: team, identifier: identifier) ?? CallerChain.executableName(path)
}

private func executablePath(_ process: pid_t) -> String? {
	var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
	guard proc_pidpath(process, &buffer, UInt32(buffer.count)) > 0 else { return nil }
	let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	return path.isEmpty ? nil : path
}

func parentProcess(of process: pid_t) -> pid_t? {
	var info = kinfo_proc()
	var size = MemoryLayout<kinfo_proc>.stride
	var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
	guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
	let parent = info.kp_eproc.e_ppid
	return parent > 1 ? parent : nil
}
