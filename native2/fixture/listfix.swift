import AppKit
import SwiftUI
// The list fixture for #225 and #227: a SwiftUI List with Set selection whose handler, like many apps', acts only
// when NSApp.currentEvent is a mouse or key event, and rows with a context menu. It logs to stdout. Build it with
// `swiftc -O -parse-as-library native2/fixture/listfix.swift -o native2/.build/listfix`.

func log(_ s: String) {
	print(s)
	fflush(stdout)
}

/// Whether the event being handled is user input, as an app that ignores programmatic selection checks it.
func userInput() -> String {
	guard let event = NSApp.currentEvent else { return "none" }
	switch event.type {
	case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown: return "user(\(event.type.rawValue))"
	default: return "other(\(event.type.rawValue))"
	}
}

final class Model: ObservableObject {
	@Published var acted: [String] = []
}

struct Rows: View {
	@State private var selection = Set<String>()
	@ObservedObject var model: Model
	let rows = ["Alpha", "Bravo", "Charlie"]

	var body: some View {
		VStack(alignment: .leading) {
			List(rows, id: \.self, selection: $selection) { row in
				Text(row)
					.contextMenu {
						Button("Rename \(row)") { act("rename \(row)") }
						Button("Delete \(row)") { act("delete \(row)") }
						Menu("More") { Button("Archive \(row)") { act("archive \(row)") } }
					}
			}
			.onChange(of: selection) { _, new in
				let how = userInput()
				log("selection \(new.sorted()) event=\(how)")
				if how.hasPrefix("user") { act("opened \(new.sorted().joined(separator: ","))") }
			}
			Text("Acted: " + (model.acted.last ?? "nothing")).padding(6)
		}
		.frame(width: 360, height: 260)
	}

	func act(_ what: String) {
		log("acted \(what)")
		model.acted.append(what)
	}
}

@main
struct ListFixture: App {
	@StateObject private var model = Model()
	var body: some Scene {
		Window("List Fixture", id: "list") { Rows(model: model) }
	}
}
