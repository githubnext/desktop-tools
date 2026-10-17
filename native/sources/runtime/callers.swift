import AppKit
import CoreGraphics
import Darwin
import DesktopToolsCallers
import Foundation
import Security

/// Who runs each client, and what the user decided for them. Callers are refused only once the embedding app
/// registers a handler to ask the user; until then every caller is served, as before.
final class Callers: @unchecked Sendable {
	static let shared = Callers()
	typealias Handler = @convention(c) (UnsafePointer<CChar>) -> Void
	private let lock = NSLock()
	private var handler: Handler?
	private var decisions: [String: Bool] = [:]
	/// Callers the app was already asked about and hasn't answered for yet.
	private var asked: Set<String> = []
	/// Each caller launch is identified once, so its signature is checked once per launch.
	private var resolved: [String: Caller] = [:]

	var enforcing: Bool {
		lock.withLock { handler != nil }
	}

	func setHandler(_ handler: Handler?) {
		lock.withLock { self.handler = handler }
	}

	/// The user's answers so far; an answered caller is never asked about again.
	func setDecisions(_ list: [CallerDecision]) {
		lock.withLock {
			decisions = Dictionary(list.map { ($0.caller.key, $0.allowed) }, uniquingKeysWith: { _, last in last })
			asked.subtract(decisions.keys)
		}
	}

	func isAllowed(_ caller: Caller) -> Bool {
		lock.withLock { decisions[caller.key] == true }
	}

	/// The refusal for a request from `client`, or nil when its caller is approved. An unknown caller is refused
	/// at once and the app is asked about it once; the client never waits for the user.
	func refusal(client: pid_t?) -> String? {
		guard enforcing else { return nil }
		guard let client, let caller = resolve(client: client)?.caller else { return CallerRefusal.unidentified }
		let (decision, ask): (Bool?, Handler?) = lock.withLock {
			let decision = decisions[caller.key]
			return (decision, decision == nil && asked.insert(caller.key).inserted ? handler : nil)
		}
		switch decision {
		case true?:
			return nil
		case false?:
			return CallerRefusal.denied(caller.name)
		case nil:
			if let ask, let data = try? JSONEncoder().encode(caller) {
				String(decoding: data, as: UTF8.self).withCString { ask($0) }
			}
			return CallerRefusal.waiting(caller.name)
		}
	}

	/// The verified caller of the client `client`, for naming it in a prompt, as filling a password does.
	func caller(ofClient client: pid_t) -> Caller? {
		resolve(client: client)?.caller
	}

	/// The verified caller of the client `client` and its pid: the nearest ancestor that isn't a launcher or shell.
	func resolve(client: pid_t) -> (caller: Caller, pid: pid_t)? {
		var chain: [(pid: pid_t, path: String)] = []
		var next = parentProcess(of: client)
		while let process = next, chain.count < 32, let path = executablePath(process) {
			chain.append((process, path))
			next = parentProcess(of: process)
		}
		guard let index = CallerChain.callerIndex(chain.map(\.path)) else { return nil }
		let (process, path) = chain[index]
		guard let start = processStart(process) else { return nil }
		let launch = "\(process) \(start)"
		if let cached = lock.withLock({ resolved[launch] }) { return (cached, process) }
		let caller = identify(process, path: path)
		// The pid could have been reused while its signature was read.
		guard processStart(process) == start else { return nil }
		lock.withLock {
			if resolved.count >= 64 { resolved.removeAll() }
			resolved[launch] = caller
		}
		return (caller, process)
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
			SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
				== errSecSuccess,
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
	return Caller(name: displayName(path, team: team, identifier: identifier), path: path, team: team,
		identifier: identifier, signer: signer)
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
	guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
		return false
	}
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

/// Desktop Tools' own processes, by the host's bundle ID, so a dev build and the installed app protect each other.
enum OwnUI {
	static let host = Bundle.main.bundleIdentifier ?? ""

	static func isOwn(_ process: pid_t) -> Bool {
		process == getpid()
			|| OwnUIGuard.isOwn(
				bundleIdentifier: NSRunningApplication(processIdentifier: process)?.bundleIdentifier, host: host)
	}

	/// Whether any of them shows a prompt or an open menu.
	static func promptOrMenuOpen() -> Bool {
		var own: Set<pid_t> = [getpid()]
		for app in NSWorkspace.shared.runningApplications
		where OwnUIGuard.isOwn(bundleIdentifier: app.bundleIdentifier, host: host) {
			own.insert(app.processIdentifier)
		}
		guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
		else { return false }
		return rows.contains { row in
			guard let owner = row[kCGWindowOwnerPID as String] as? Int32, own.contains(owner) else { return false }
			return OwnUIGuard.isPromptOrMenu(
				layer: row[kCGWindowLayer as String] as? Int ?? 0,
				sharingState: row[kCGWindowSharingState as String] as? Int ?? 1,
				onScreen: true)
		}
	}
}
