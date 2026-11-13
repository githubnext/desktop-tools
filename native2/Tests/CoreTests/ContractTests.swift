import DesktopProtocol
import Testing

/// The tool declarations in ContractTools.swift, which the MCP server serves and /tools exports (#237).
@Suite struct ContractDeclarations {
	@Test func namesAreUniqueAndEveryToolIsAnObjectSchema() {
		#expect(Contract.names.count == Contract.declared.count)
		for tool in Contract.declared {
			#expect(tool.parameters["type"]?.string == "object", "\(tool.name)")
			#expect(tool.parameters["properties"]?.pairs != nil, "\(tool.name)")
			#expect(tool.name == "desktop_" + tool.op.replacingOccurrences(of: "-", with: "_"))
		}
	}

	@Test func exportMarksOnlyThePlaceAndTheApp() {
		// The export stands {{place}} and {{app}} in for them, so no other text may contain the markers.
		let text = Contract.listed(place: "P", app: "A").text + Contract.instructions(app: "A")
		#expect(!text.contains("{{"))
		let exported = Contract.export()
		#expect(exported["tools"]?.array?.count == Contract.declared.count)
		#expect(exported["tools"]?.text.contains("{{place}}") == true)
		#expect(exported["rules"]?.text.contains("{{app}}") == true)
	}

	@Test func listMarksActionsAsNotReadOnly() {
		for tool in Contract.tools.array ?? [] {
			let name = tool["name"]?.string ?? ""
			#expect(tool["annotations"]?["readOnlyHint"]?.bool == !Contract.actions.contains(name), "\(name)")
		}
	}

	@Test func clickKeySystemKeyDragAndInsertTakeExpect() {
		#expect(Contract.expecting == ["desktop_click", "desktop_drag", "desktop_insert", "desktop_key", "desktop_system_key"])
		#expect(Contract.expecting.isSubset(of: Contract.actions))
	}

	@Test func instructionsEndWithTheSharedRules() {
		let rules = Contract.rules(app: "Desktop Tools").joined(separator: "\n")
		#expect(Contract.instructions.hasSuffix("\n\n" + rules))
		#expect(Contract.instructions.hasPrefix("Use desktop_* tools to observe and operate native apps on this Mac through Desktop Tools,"))
	}
}
