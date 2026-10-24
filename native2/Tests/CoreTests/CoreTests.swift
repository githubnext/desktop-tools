import DesktopCore
import DesktopProtocol
import Testing

@Suite struct JSONText {
	@Test func writesAsJSONStringify() throws {
		let value: JSON = .object([
			("int", 3), ("float", 295.16796875), ("negative", -0.5), ("big", 1792438875817382),
			("text", "a\"b\\c\n\t\u{01}/é😀"), ("list", [true, false, .null]), ("empty", .object([])),
		])
		#expect(value.text == #"{"int":3,"float":295.16796875,"negative":-0.5,"big":1792438875817382,"text":"a\"b\\c\n\t\u0001/é😀","list":[true,false,null],"empty":{}}"#)
	}

	@Test func parsesAndKeepsKeyOrder() throws {
		let text = #"{"z":1,"a":[1.5,"é😀",{"k":null}],"m":"x\/y"}"#
		let value = try JSON(parsing: text)
		#expect(value.text == #"{"z":1,"a":[1.5,"é😀",{"k":null}],"m":"x/y"}"#)
	}

	@Test func rejectsTrailingText() {
		#expect(throws: JSONParseError.self) { try JSON(parsing: "{} x") }
	}
}

@Suite struct Bounding {
	@Test func dropsLastValuesUntilItFits() throws {
		let data: JSON = .object([("items", .array((0..<100).map { JSON("item \($0)") })), ("after", 1)])
		let text = try bounded(data, field: "items", limit: 200)
		let result = try JSON(parsing: text)
		#expect(text.utf8.count <= 200)
		#expect(result["truncated"] == true)
		#expect(result["omitted"]?.int == 100 - (result["items"]?.array?.count ?? 0))
		#expect(result["items"]?.array?.first == "item 0")
	}

	@Test func dropsKeptValuesLast() throws {
		let filler = JSON(String(repeating: "x", count: 20))
		let data: JSON = .object([("items", ["keep", filler, filler, "keep", filler])])
		let text = try bounded(data, field: "items", limit: 60) { $0 == "keep" }
		#expect(try JSON(parsing: text)["items"] == ["keep", "keep"])
	}

	@Test func dropsFirstValuesBeforeOthers() throws {
		let filler = { (name: String) in JSON(name + String(repeating: "x", count: 20)) }
		let data: JSON = .object([("items", [filler("a"), filler("off1"), "keep", filler("b"), filler("off2")])])
		let text = try bounded(data, field: "items", limit: 110, dropFirst: ({ $0.string?.hasPrefix("off") == true }, "offscreen")) {
			$0 == "keep"
		}
		let result = try JSON(parsing: text)
		#expect(result["items"] == [filler("a"), "keep", filler("b")])
		#expect(result["omitted"]?.int == 2)
		#expect(result["offscreen"]?.int == 2)
	}

	@Test func leavesSmallResultsAlone() throws {
		let data: JSON = .object([("items", [1, 2])])
		#expect(try bounded(data, field: "items") == #"{"items":[1,2]}"#)
	}
}

@Suite struct Availability {
	@Test func otherSpaceNamesTheSpace() {
		let row: JSON = .object([("space_ids", [7]), ("display_current_space_id", 1), ("is_on_screen", false)])
		let result = windowAvailability(row, sessionLocked: false, appHidden: false)
		#expect(result["reason"] == "other_space")
		#expect(result["space_id"] == 7)
	}

	@Test func panelServiceWindowPointsToTheApp() {
		let row: JSON = .object([("is_on_screen", false), ("observation_capability", "pixels_only"), ("observation_reason", "open_save_panel_service")])
		let result = windowAvailability(row, sessionLocked: false, appHidden: false)
		#expect(result["reason"] == "open_save_panel_service")
		#expect(result["state"] == "unavailable")
	}

	@Test func lockedComesFirst() {
		let row: JSON = .object([("is_minimized", true)])
		#expect(windowAvailability(row, sessionLocked: true, appHidden: true)["reason"] == "session_locked")
	}

	@Test func pixelsOnlyIsLimitedWithCause() {
		let row: JSON = .object([("is_on_screen", true), ("observation_capability", "pixels_only"), ("observation_reason", "ax_window_missing")])
		let result = windowAvailability(row, sessionLocked: false, appHidden: false)
		#expect(result["state"] == "limited")
		#expect(result["cause"] == "ax_window_missing")
	}

	@Test func visibleIsAvailable() {
		let row: JSON = .object([("is_on_screen", true), ("space_ids", [1]), ("display_current_space_id", 1)])
		#expect(windowAvailability(row, sessionLocked: false, appHidden: false)["reason"] == "visible")
	}
}

@Suite struct ContractShape {
	@Test func servesAllTools() {
		#expect(Contract.names.count == 48)
		#expect(Contract.actions.contains("desktop_click"))
		#expect(!Contract.actions.contains("desktop_apps"))
		#expect(Contract.instructions.hasPrefix("Use desktop_* tools"))
	}
}
