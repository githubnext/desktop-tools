import DesktopCore
import Foundation
import Testing

struct CallersTests {
	@Test
	func `the caller is the first ancestor that is not a launcher or shell`() {
		// desktop-tools-client's parent upward, as Claude Code runs the MCP server.
		let chain = ["/opt/node/bin/node", "/bin/zsh", "/Users/me/.local/share/claude/versions/2.1.302", "/bin/zsh",
			"/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty"]
		#expect(CallerChain.callerIndex(chain) == 2)
		// From a terminal: the terminal app.
		#expect(CallerChain.callerIndex(["/opt/node/bin/node", "/opt/node/bin/npx", "-zsh", "/usr/bin/login",
			"/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]) == 4)
		// Nothing but launchers, as under launchd: the outermost.
		#expect(CallerChain.callerIndex(["/opt/node/bin/node", "/bin/sh"]) == 1)
		#expect(CallerChain.callerIndex([]) == nil)
	}

	@Test
	func `signed callers keep their approval across moves; others are pinned to their path`() {
		let old = Caller(name: "claude", path: "/v/2.1.301", team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code",
			signer: "Anthropic PBC")
		let new = Caller(name: "claude", path: "/v/2.1.302", team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code",
			signer: "Anthropic PBC")
		#expect(old.key == new.key)
		#expect(old.key == "team:Q6L2SF6YDW:com.anthropic.claude-code")
		#expect(Caller.key(path: "/usr/bin/perl", team: nil, identifier: "com.apple.perl") == "path:/usr/bin/perl id:com.apple.perl")
		#expect(Caller.key(path: "/tmp/agent", team: nil, identifier: nil) == "path:/tmp/agent")
		#expect(Caller.key(path: "/tmp/agent", team: "", identifier: "x") == "path:/tmp/agent id:x")
	}

	@Test
	func `team-signed tools are named from their signature, not their file`() {
		#expect(CallerChain.signedName(team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code") == "claude-code")
		#expect(CallerChain.signedName(team: nil, identifier: "com.apple.perl") == nil)
		#expect(CallerChain.signedName(team: "T", identifier: nil) == nil)
	}

	@Test
	func `helpers are named after the outermost app`() {
		#expect(CallerChain.appBundle(of: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
			== "/Applications/Claude.app")
		#expect(CallerChain.appBundle(of: "/usr/bin/perl") == nil)
	}

	@Test
	func `decisions survive a save and load, and a missing file means none`() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("callers-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(CallerDecisions.load(url).isEmpty)
		let decisions = [CallerDecision(
			caller: Caller(name: "perl", path: "/usr/bin/perl", team: nil, identifier: "com.apple.perl", signer: "Apple"),
			allowed: false, decided: 1_800_000_000)]
		try CallerDecisions.save(decisions, to: url)
		#expect(CallerDecisions.load(url) == decisions)
		let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
		#expect(mode == 0o600)
	}

	@Test
	func `refusals start with their code`() {
		#expect(CallerRefusal.waiting("claude").hasPrefix("CALLER_NOT_APPROVED: "))
		#expect(CallerRefusal.denied("perl").hasPrefix("CALLER_NOT_APPROVED: "))
		#expect(CallerRefusal.ownWindow.hasPrefix("SELF_TARGET_REFUSED: "))
		#expect(CallerRefusal.ownUIOpen.hasPrefix("SELF_TARGET_REFUSED: "))
	}

	@Test
	func `input to the host's own UI is refused, and so is any input while its prompt or menu is open`() {
		#expect(OwnUIGuard.refusal(input: true, targetIsOwn: true, ownUIOpen: false) == CallerRefusal.ownWindow)
		#expect(OwnUIGuard.refusal(input: true, targetIsOwn: false, ownUIOpen: true) == CallerRefusal.ownUIOpen)
		#expect(OwnUIGuard.refusal(input: true, targetIsOwn: false, ownUIOpen: false) == nil)
		// Observing is always fine.
		#expect(OwnUIGuard.refusal(input: false, targetIsOwn: true, ownUIOpen: true) == nil)
	}

	@Test
	func `the family is the host's bundle and everything under it`() {
		let host = "dev.githubnext.desktop-tools"
		#expect(OwnUIGuard.isOwn(bundleIdentifier: host, host: host))
		#expect(OwnUIGuard.isOwn(bundleIdentifier: host + ".desktop-client", host: host))
		#expect(!OwnUIGuard.isOwn(bundleIdentifier: "dev.githubnext.desktop-toolsx", host: host))
		#expect(!OwnUIGuard.isOwn(bundleIdentifier: nil, host: host))
		#expect(!OwnUIGuard.isOwn(bundleIdentifier: host, host: ""))
		// A dev build named under the app's ID, and the installed app seen from it.
		#expect(OwnUIGuard.isOwn(bundleIdentifier: host + ".dev", host: host))
		#expect(OwnUIGuard.isOwn(bundleIdentifier: host, host: host + ".dev"))
		#expect(OwnUIGuard.isOwn(bundleIdentifier: host + ".dev.desktop-client", host: host + ".dev"))
		#expect(!OwnUIGuard.isOwn(bundleIdentifier: "", host: host))
	}

	@Test
	func `prompts and menus count; the status item and unshared overlays don't`() {
		#expect(OwnUIGuard.isPromptOrMenu(layer: 101, sharingState: 1, onScreen: true)) // open menu
		#expect(OwnUIGuard.isPromptOrMenu(layer: 8, sharingState: 1, onScreen: true)) // modal alert
		#expect(!OwnUIGuard.isPromptOrMenu(layer: 25, sharingState: 1, onScreen: true)) // status item
		#expect(!OwnUIGuard.isPromptOrMenu(layer: 1000, sharingState: 0, onScreen: true)) // agent cursor
		#expect(!OwnUIGuard.isPromptOrMenu(layer: 8, sharingState: 1, onScreen: false))
	}

	@Test
	func `a caller with no app or signed program above it is told why it can't be approved`() {
		let message = CallerRefusal.detached(["node", "agent"])
		#expect(message.hasPrefix("CALLER_NOT_APPROVED: "))
		#expect(message.contains("(node > agent) reach launchd with no app and no program signed by a developer team"))
		#expect(message.contains("there is no prompt for the user to answer"))
		#expect(CallerRefusal.detached([]).contains("its client's parent is launchd, with no app or program signed by a developer team above it, as when"))
	}
}
