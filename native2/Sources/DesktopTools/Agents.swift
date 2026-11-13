import AppKit
import DesktopCore
import DesktopHost
import Foundation

/// Who an agent is on screen: the name on its cursor and outline, its color, and the key that gives each agent its own
/// cursor and outline. Claude is orange and Codex blue; any other agent gets a color from its key, the same every time.
struct AgentIdentity: Sendable, Equatable {
	struct Tint: Sendable, Equatable {
		let red: CGFloat, green: CGFloat, blue: CGFloat

		var color: CGColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor }
		/// Darkened, to edge the label.
		var rim: CGColor { NSColor(srgbRed: red * 0.65, green: green * 0.58, blue: blue * 0.55, alpha: 1).cgColor }
	}

	static let claude = Tint(red: 0.85, green: 0.47, blue: 0.34)
	static let codex = Tint(red: 0.30, green: 0.55, blue: 0.98)
	/// For every other agent, picked by key: none is close to Claude's orange or Codex's blue.
	static let others = [
		Tint(red: 0.30, green: 0.72, blue: 0.45), Tint(red: 0.60, green: 0.42, blue: 0.95), Tint(red: 0.92, green: 0.38, blue: 0.62),
		Tint(red: 0.18, green: 0.68, blue: 0.72), Tint(red: 0.86, green: 0.66, blue: 0.18), Tint(red: 0.84, green: 0.30, blue: 0.30),
	]

	/// Input outside any call, which no agent asked for.
	static let unknown = AgentIdentity(key: "agent", name: "Agent", tint: claude)

	let key: String
	let name: String
	let tint: Tint

	/// The agent behind `client`, the connected MCP binary: its `DESKTOP_TOOLS_AGENT` name when the server passed one,
	/// else the program that runs it, as approvals name it. Resolved off the main thread while the client still waits
	/// for its reply, and kept for a minute, since one client sends many calls.
	static func of(client: pid_t?, agent: Hooks.Agent? = nil) -> AgentIdentity {
		// A client that serves several agents names each call's own, so the cursor and outline follow that agent.
		if let agent {
			return make(key: "agent:\(agent.key)", named: agent.name, words: [agent.kind], caller: nil, kind: agent.kind)
		}
		guard let client else { return unknown }
		lock.lock()
		if let (identity, at) = cache[client], Date().timeIntervalSince(at) < 60 {
			lock.unlock()
			return identity
		}
		lock.unlock()
		let named = agentName(of: client)
		let caller = Callers.shared.resolve(client: client)?.caller
		let key = (caller?.key ?? "client:\(client)") + (named.map { " as:\($0)" } ?? "")
		let identity = make(key: key, named: named, words: [caller?.identifier, caller?.name, caller?.path], caller: caller?.name)
		lock.lock()
		cache[client] = (identity, Date())
		lock.unlock()
		return identity
	}

	/// Claude's orange when its name or program says Claude, Codex's blue when it says Codex, else a color from `key`.
	static func make(key: String, named: String?, words: [String?], caller: String?, kind: String? = nil) -> AgentIdentity {
		// A named kind wins over words in the name, so a Codex thread titled "Claude notes" is still blue.
		let text = kind.map { $0.lowercased() } ?? ([named] + words).compactMap { $0?.lowercased() }.joined(separator: " ")
		if text.contains("claude") { return AgentIdentity(key: key, name: named ?? "Claude", tint: claude) }
		if text.contains("codex") { return AgentIdentity(key: key, name: named ?? "Codex", tint: codex) }
		return AgentIdentity(key: key, name: named ?? caller ?? "Agent", tint: others[Int(fnv(key) % UInt64(others.count))])
	}

	private static let lock = NSLock()
	nonisolated(unsafe) private static var cache: [pid_t: (AgentIdentity, Date)] = [:]

	/// FNV-1a, which unlike `hashValue` is the same in every process.
	static func fnv(_ text: String) -> UInt64 {
		text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
	}
}
