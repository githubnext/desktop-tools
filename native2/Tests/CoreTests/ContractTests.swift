import DesktopProtocol
import Testing

/// The tool declarations in Swift must serve exactly what the Node server does until the server switches to them (#237).
@Suite struct ContractDeclarations {
	@Test func listMatchesTheGeneratedContract() {
		let declared = Contract.listed(place: "this Mac", app: "Desktop Tools")
		let generated = Contract.tools
		#expect(declared.array?.count == generated.array?.count)
		for (mine, theirs) in zip(declared.array ?? [], generated.array ?? []) {
			#expect(mine.text == theirs.text, "\(theirs["name"]?.string ?? "?")")
		}
		#expect(declared.text == generated.text)
	}

	@Test func instructionsMatchTheGeneratedContract() {
		#expect(Contract.instructions(app: "Desktop Tools") == Contract.instructions)
	}

	@Test func actionsMatchTheAnnotations() {
		let declared = Set(Contract.definitions(place: "this Mac", app: "Desktop Tools").filter(\.action).map(\.name))
		#expect(declared == Contract.actions)
	}
}
