import Foundation

/// A program that asks Desktop Tools to act: the nearest meaningful ancestor of the process that ran the client,
/// such as Claude Code, Codex or a terminal app. Approvals are remembered per caller.
public struct Caller: Codable, Equatable, Sendable {
	/// What approvals are keyed on: the team ID and signing identifier of validly signed code, else its path.
	public let key: String
	/// The name shown in prompts, menus and the activity log.
	public let name: String
	public let path: String
	/// Set only when the signature validated.
	public let team: String?
	public let identifier: String?
	/// Who signed it, such as "Anthropic PBC" or "Apple", when the signature validated.
	public let signer: String?

	public init(name: String, path: String, team: String?, identifier: String?, signer: String?) {
		self.key = Self.key(path: path, team: team, identifier: identifier)
		self.name = name
		self.path = path
		self.team = team
		self.identifier = identifier
		self.signer = signer
	}

	/// Signed code with a team keeps its approval across updates that move it, as Claude Code's versioned path does.
	/// Everything else is pinned to its path, plus its identifier when it has one.
	public static func key(path: String, team: String?, identifier: String?) -> String {
		if let team, !team.isEmpty, let identifier, !identifier.isEmpty { return "team:\(team):\(identifier)" }
		if let identifier, !identifier.isEmpty { return "path:\(path) id:\(identifier)" }
		return "path:\(path)"
	}

	/// One line on who this is, for the prompt and the menu.
	public var origin: String {
		let signed = signer.map { team.map { "Signed by \(signer!) (\($0))" } ?? "Signed by \($0)" } ?? "Not signed"
		return "\(signed). \(path)"
	}
}

/// Picks the caller out of the client's ancestors.
public enum CallerChain {
	/// Launchers and shells that only run the agent; the caller is above them.
	public static let launchers: Set<String> = [
		"node", "npx", "npm", "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "env",
	]

	/// The caller among `paths`, the executables from the client's parent upward: the first that isn't a launcher or
	/// shell, or, when all are, the outermost one.
	public static func callerIndex(_ paths: [String]) -> Int? {
		guard !paths.isEmpty else { return nil }
		return paths.firstIndex { !launchers.contains(executableName($0)) } ?? paths.count - 1
	}

	public static func executableName(_ path: String) -> String {
		let name = (path as NSString).lastPathComponent
		return name.hasPrefix("-") ? String(name.dropFirst()) : name
	}

	/// The last part of a team-signed identifier, such as `claude-code` for `com.anthropic.claude-code`.
	public static func signedName(team: String?, identifier: String?) -> String? {
		guard let team, !team.isEmpty, let identifier,
			let last = identifier.split(separator: ".").last, !last.isEmpty
		else { return nil }
		return String(last)
	}

	/// The outermost app bundle holding `path`, so a helper inside an app is named after the app.
	public static func appBundle(of path: String) -> String? {
		let components = (path as NSString).pathComponents
		guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
		return NSString.path(withComponents: Array(components[...index]))
	}
}

/// The user's answers, kept in `callers.json` in the state directory.
public struct CallerDecision: Codable, Equatable, Sendable {
	public let caller: Caller
	public var allowed: Bool
	/// Seconds since 1970.
	public var decided: Double

	public init(caller: Caller, allowed: Bool, decided: Double) {
		self.caller = caller
		self.allowed = allowed
		self.decided = decided
	}
}

public enum CallerDecisions {
	public static let fileName = "callers.json"

	/// A missing or unreadable file means no answers yet, so every caller is asked again.
	public static func load(_ url: URL) -> [CallerDecision] {
		guard let data = try? Data(contentsOf: url) else { return [] }
		return (try? JSONDecoder().decode([CallerDecision].self, from: data)) ?? []
	}

	public static func save(_ decisions: [CallerDecision], to url: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(decisions).write(to: url, options: [.atomic])
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
	}
}

/// The refusals agents see. Each starts with its code, which the MCP server turns into the result's error code.
public enum CallerRefusal {
	public static let notApproved = "CALLER_NOT_APPROVED"
	public static let selfTarget = "SELF_TARGET_REFUSED"

	public static func waiting(_ name: String) -> String {
		"\(notApproved): Desktop Tools hasn't approved \(name) to control this Mac yet, so nothing ran. Ask the user to choose Allow in the Desktop Tools prompt, or under Approved Agents in its menu, then try again."
	}

	public static func denied(_ name: String) -> String {
		"\(notApproved): The user chose Don't Allow for \(name) in Desktop Tools, so nothing ran. Only the user can allow it, under Approved Agents in the Desktop Tools menu."
	}

	public static let unidentified =
		"\(notApproved): Desktop Tools couldn't identify the program that ran its client, so nothing ran. Run the agent from a terminal or app the user can approve."

	public static let ownWindow =
		"\(selfTarget): Desktop Tools' own menus, prompts and windows answer only to the user, so nothing was sent. Ask the user to act on them."

	public static let ownUIOpen =
		"\(selfTarget): A Desktop Tools prompt or menu is open, and only the user may answer it, so nothing was sent. Try again once the user has closed it."
}

/// Agent input that could reach Desktop Tools' own UI is refused, so only the user can approve callers or pause.
public enum OwnUIGuard {
	/// `input` is whether the request sends input or changes a window or app; `targetIsOwn` whether its target
	/// process belongs to the host's bundle family; `ownUIOpen` whether one of the family's prompts or menus is shown.
	public static func refusal(input: Bool, targetIsOwn: Bool, ownUIOpen: Bool) -> String? {
		guard input else { return nil }
		if targetIsOwn { return CallerRefusal.ownWindow }
		// Untargeted or pointer input could land on the prompt, and keys go to it once it's frontmost.
		if ownUIOpen { return CallerRefusal.ownUIOpen }
		return nil
	}

	/// The host's bundle, every bundle under it, such as its client or a dev build named under the app's ID, and
	/// the bundle it is itself named under, so a dev build and the installed app guard each other.
	public static func isOwn(bundleIdentifier: String?, host: String) -> Bool {
		guard let bundleIdentifier, !host.isEmpty, !bundleIdentifier.isEmpty else { return false }
		return bundleIdentifier == host || bundleIdentifier.hasPrefix(host + ".") || host.hasPrefix(bundleIdentifier + ".")
	}

	/// One WindowServer row of a family process. The status item stays up, and the agent cursor and window outline
	/// are never shared, so neither counts as a prompt or menu.
	public static func isPromptOrMenu(layer: Int, sharingState: Int, onScreen: Bool) -> Bool {
		onScreen && sharingState != 0 && layer != statusItemLayer
	}

	/// kCGStatusWindowLevel.
	public static let statusItemLayer = 25
}
