@testable import DesktopTools
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
}
