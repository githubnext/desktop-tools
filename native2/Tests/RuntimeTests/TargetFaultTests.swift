@testable import DesktopHost
@testable import DesktopMac
import DesktopProtocol
import Foundation
import Testing

/// Target refusals name the field to fix, and cover refusals the window found (#196).
struct TargetFaultTests {
	static func fault(_ arguments: String, window: Bool = true) throws -> String {
		let json = try JSON(parsing: arguments)
		return Tools.targetFault(json["target"], json, window: window)
	}

	@Test
	func `a pid and window passed loose are named`() throws {
		#expect(try Self.fault(#"{"pid": 1, "window": 2}"#) == "target is missing; pid and window at the top level aren't read. Pass a window's target from desktop_windows as target.")
		#expect(try Self.fault("{}", window: false) == "target is missing. Pass an app's target from desktop_apps as target.")
	}

	@Test
	func `each malformed field is named`() throws {
		#expect(try Self.fault(#"{"target": "x"}"#).hasPrefix("target must be the object itself, not a string."))
		#expect(try Self.fault(#"{"target": {"pid": 0}}"#) == "target.pid is missing or not a positive whole number.")
		#expect(try Self.fault(#"{"target": {"pid": 5, "process_start_identity_decimal": 17}}"#).hasPrefix("target.process_start_identity_decimal must be the decimal string"))
		#expect(try Self.fault(#"{"target": {"pid": 5, "process_start_identity_decimal": "17"}}"#).hasPrefix("target.window_id is missing; this is an app's target"))
		#expect(try Self.fault(#"{"target": {"pid": 5, "process_start_identity_decimal": "17", "window_id": 3, "is_minimized": false, "bounds": {"x": 0, "y": 0, "width": 10}}}"#) == "target.bounds.height is missing or not a number.")
	}

	@Test
	func `the covering window is described by owner, title and layer`() {
		let window = WindowAtPoint(id: 7, pid: 42, owner: "CleanShot X", title: "", layer: 25, bounds: .zero)
		#expect(window.description == "window 7 of CleanShot X, at layer 25")
		#expect(WindowAtPoint(id: 8, pid: 42, owner: "", title: "Ace", layer: 0, bounds: .zero).description == #"window 8 of PID 42 ("Ace")"#)
	}
}
