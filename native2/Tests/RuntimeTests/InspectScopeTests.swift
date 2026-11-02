import CoreGraphics
@testable import DesktopHost
@testable import DesktopMac
import DesktopProtocol
import Foundation
import Testing

/// An action's expect takes its target from the action's snapshot (#224).
struct ExpectTargetTests {
	static func filled(_ expect: String) throws -> JSON {
		Tools.expectTarget(try JSON(parsing: expect), pid: 42, window: 7)
	}

	@Test
	func `a window condition takes the snapshot's pid and window`() throws {
		let expect = try Self.filled(#"{"until": "element_appears", "element": {"role": "AXSheet", "title": "Done"}}"#)
		#expect(expect["pid"]?.int == 42)
		#expect(expect["window"]?.int == 7)
		#expect(throws: Never.self) { try Tools.expectation(.object([("expect", expect)])) }
		for until in ["window_gone", "text_changes"] {
			let other = try Self.filled(#"{"until": "\#(until)"}"#)
			#expect(other["pid"]?.int == 42 && other["window"]?.int == 7)
		}
	}

	@Test
	func `a dialog condition takes only the pid, so it reads the whole app`() throws {
		let expect = try Self.filled(#"{"until": "dialog_appears"}"#)
		#expect(expect["pid"]?.int == 42)
		#expect(expect["window"] == nil)
		#expect(throws: Never.self) { try Tools.expectation(.object([("expect", expect)])) }
	}

	@Test
	func `an app condition takes the pid unless it names a bundle ID`() throws {
		#expect(try Self.filled(#"{"until": "app_quit"}"#)["pid"]?.int == 42)
		let named = try Self.filled(#"{"until": "window_appears", "bundle_id": "com.apple.TextEdit"}"#)
		#expect(named["pid"] == nil)
		#expect(throws: Never.self) { try Tools.expectation(.object([("expect", named)])) }
	}

	@Test
	func `a condition naming another app keeps it, and doesn't borrow this window`() throws {
		let expect = try Self.filled(#"{"until": "element_appears", "pid": 9, "element": {"role": "AXButton", "title": "OK"}}"#)
		#expect(expect["pid"]?.int == 9)
		#expect(expect["window"] == nil)
		let window = try Self.filled(#"{"until": "element_gone", "window": 3, "element": {"role": "AXButton", "title": "OK"}}"#)
		#expect(window["pid"]?.int == 42 && window["window"]?.int == 3)
	}

	@Test
	func `without a snapshot, the refusal names expect's missing field`() throws {
		let arguments = try JSON(parsing: #"{"expect": {"until": "dialog_appears"}}"#)
		let error = #expect(throws: ToolError.self) { try Tools.expectation(arguments) }
		#expect(error?.message == "expect: pid must be a positive integer.")
	}
}

/// A visible-only walk leaves out what lies outside the window or the scroll or web area around it (#178).
struct VisibleClipTests {
	let window = CGRect(x: 100, y: 50, width: 1298, height: 953)

	@Test
	func `elements far above or below the window are outside it, and partly visible ones aren't`() {
		#expect(VisibleClip.outside(CGRect(x: 337, y: -739, width: 949, height: 51), clip: window))
		#expect(VisibleClip.outside(CGRect(x: 337, y: 2733, width: 949, height: 41), clip: window))
		#expect(!VisibleClip.outside(CGRect(x: 337, y: 96, width: 949, height: 7117), clip: window))
		#expect(!VisibleClip.outside(CGRect(x: 337, y: 990, width: 949, height: 41), clip: window))
		#expect(!VisibleClip.outside(CGRect(x: 337, y: 2733, width: 949, height: 41), clip: nil))
	}

	@Test
	func `a scroll or web area narrows the clip for its descendants, and other roles don't`() {
		let viewport = CGRect(x: 100, y: 130, width: 1298, height: 873)
		#expect(VisibleClip.narrowed(window, role: "AXWebArea", frame: viewport) == viewport)
		let sidebar = CGRect(x: 100, y: 130, width: 200, height: 400)
		let clip = VisibleClip.narrowed(window, role: "AXScrollArea", frame: sidebar)
		#expect(clip == sidebar)
		// A row scrolled out of the sidebar is still inside the window, but outside its scroll area.
		#expect(VisibleClip.outside(CGRect(x: 100, y: 600, width: 200, height: 24), clip: clip))
		#expect(VisibleClip.narrowed(window, role: "AXGroup", frame: sidebar) == window)
		#expect(VisibleClip.narrowed(nil, role: "AXScrollArea", frame: sidebar) == nil)
		// A scroll area wholly outside the clip leaves the clip as it was rather than empty.
		#expect(VisibleClip.narrowed(window, role: "AXScrollArea", frame: CGRect(x: 0, y: 5000, width: 10, height: 10)) == window)
	}
}

/// A wait that matched an element past the inspection's budget lists the subtree around it (#232).
struct ListingRootTests {
	@Test
	func `the root is the outermost ancestor whose subtree fits the limit`() {
		// window(0) > web area(1) > form(2) > [label(3), field(3)], then a long list(2) > 6 rows(3).
		let depths = [0, 1, 2, 3, 3, 2, 3, 3, 3, 3, 3, 3]
		#expect(WaitCondition.listingRoot(depths: depths, match: 4, limit: 3) == 2)
		#expect(WaitCondition.listingRoot(depths: depths, match: 4, limit: 100) == 0)
		#expect(WaitCondition.listingRoot(depths: depths, match: 4, limit: 1) == 4)
		#expect(WaitCondition.listingRoot(depths: depths, match: 9, limit: 7) == 5)
		#expect(WaitCondition.listingRoot(depths: depths, match: 0, limit: 1) == 0)
	}
}

/// Web accessibility this host turned on is turned back off once idle or when asked; one found on never is (#231).
struct WebAccessibilityLedgerTests {
	let chrome = Generation(pid: 10, start: 1)
	let slack = Generation(pid: 20, start: 2)

	@Test
	func `only launches this host turned on are released`() {
		var ledger = WebAccessibilityLedger()
		ledger.turnedOn(chrome, via: .enhanced_ui, at: .now)
		ledger.foundOn(slack)
		#expect(ledger.release(slack) == nil)
		#expect(ledger.on.contains(slack))
		#expect(ledger.release(chrome) == .enhanced_ui)
		#expect(!ledger.on.contains(chrome))
		#expect(ledger.release(chrome) == nil)
	}

	@Test
	func `a read keeps it from going idle, and ended launches are forgotten`() {
		var ledger = WebAccessibilityLedger()
		let start = ContinuousClock.now
		ledger.turnedOn(chrome, via: .manual, at: start)
		ledger.turnedOn(slack, via: .manual, at: start)
		let used = ledger.use(chrome, at: start + .seconds(500))
		#expect(used)
		let idle = ledger.idle(.seconds(600), at: start + .seconds(700)) { _ in true }
		#expect(idle == [slack])
		#expect(ledger.idle(.seconds(600), at: start + .seconds(1100)) { _ in true } == [chrome, slack])
		#expect(ledger.idle(.seconds(600), at: start + .seconds(1100)) { $0 != slack } == [chrome])
		#expect(!ledger.on.contains(slack) && ledger.owned[slack] == nil)
		let forgotten = !ledger.use(slack, at: start)
		#expect(forgotten)
	}
}
