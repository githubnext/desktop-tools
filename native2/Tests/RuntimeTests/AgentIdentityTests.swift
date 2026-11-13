import Darwin
@testable import DesktopTools
import DesktopHost
import DesktopProtocol
import Testing

struct AgentIdentityTests {
	@Test
	func `Claude is orange and Codex blue, by name or by the program that runs them`() {
		let claude = AgentIdentity.make(key: "a", named: nil, words: ["com.anthropic.claudefordesktop", nil, nil], caller: "Claude")
		#expect(claude.tint == AgentIdentity.claude)
		#expect(claude.name == "Claude")
		let codex = AgentIdentity.make(key: "b", named: nil, words: [nil, nil, "/opt/homebrew/bin/codex"], caller: "codex")
		#expect(codex.tint == AgentIdentity.codex)
		#expect(codex.name == "Codex")
		let named = AgentIdentity.make(key: "c", named: "Codex", words: [nil, "Ghostty", nil], caller: "Ghostty")
		#expect(named.tint == AgentIdentity.codex)
		#expect(named.name == "Codex")
	}

	@Test
	func `any other agent gets a palette color that its key fixes`() {
		let gemini = AgentIdentity.make(key: "team:X as:Gemini", named: "Gemini", words: [nil, "Ghostty", nil], caller: "Ghostty")
		#expect(gemini.name == "Gemini")
		#expect(AgentIdentity.others.contains(gemini.tint))
		#expect(AgentIdentity.make(key: "team:X as:Gemini", named: "Gemini", words: [], caller: nil).tint == gemini.tint)
		let tints = Set((0..<40).map { AgentIdentity.make(key: "agent \($0)", named: nil, words: [], caller: nil).tint.red })
		#expect(tints.count > 3)
		#expect(AgentIdentity.make(key: "k", named: nil, words: [], caller: nil).name == "Agent")
		#expect(AgentIdentity.fnv("a") == 0xaf63_dc4c_8601_ec8c)
	}

	@Test
	func `an agent the request names wins over its client, and its kind picks the color`() throws {
		let request = try JSON(parsing: #"{"key": "thread-1", "name": "  Claude notes  ", "kind": "codex"}"#)
		let agent = try #require(Hooks.Agent(request))
		#expect(agent.name == "Claude notes")
		let identity = AgentIdentity.of(client: getpid(), agent: agent)
		#expect(identity.name == "Claude notes")
		#expect(identity.tint == AgentIdentity.codex)
		#expect(identity.key == "agent:thread-1")
		#expect(AgentIdentity.of(client: getpid(), agent: Hooks.Agent(key: "thread-2", name: "Lane", kind: "claude")).tint == AgentIdentity.claude)
		// Each thread gets its own cursor and outline.
		#expect(AgentIdentity.of(client: getpid(), agent: Hooks.Agent(key: "thread-3", name: "Lane", kind: nil)).key != identity.key)
	}

	@Test
	func `a request's agent needs a key and a name`() throws {
		#expect(Hooks.Agent(try JSON(parsing: #"{"name": "x"}"#)) == nil)
		#expect(Hooks.Agent(try JSON(parsing: #"{"key": "k", "name": "   "}"#)) == nil)
		#expect(Hooks.Agent(nil) == nil)
		#expect(Hooks.Agent(try JSON(parsing: #"{"key": "k", "name": "\#(String(repeating: "a", count: 60))"}"#))?.name.count == 40)
	}
}
