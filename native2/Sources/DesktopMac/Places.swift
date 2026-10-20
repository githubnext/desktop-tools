import AppKit
import CoreGraphics

// WindowServer's Spaces, from private SkyLight calls that the shipping client already relies on.
private typealias SpacesConnection = Int32
@_silgen_name("_CGSDefaultConnection") private func spacesDefaultConnection() -> SpacesConnection
@_silgen_name("CGSCopyManagedDisplaySpaces") private func spacesCopyManagedDisplaySpaces(_ connection: SpacesConnection) -> CFArray?
@_silgen_name("CGSCopySpacesForWindows")
private func spacesCopySpacesForWindows(_ connection: SpacesConnection, _ mask: Int32, _ windows: CFArray) -> CFArray?

/// An active display; CoreGraphics lists the main display first, so index 0 is the main display.
struct Display {
	let index: Int
	let id: CGDirectDisplayID
	let bounds: CGRect
	let isMain: Bool
}

func activeDisplays() -> [Display] {
	var count: UInt32 = 0
	guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
	var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
	guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
	return ids.prefix(Int(count)).enumerated().map { index, id in
		Display(index: index, id: id, bounds: CGDisplayBounds(id), isMain: CGDisplayIsMain(id) != 0)
	}
}

/// The display holding most of a rectangle in global top-left points.
func displayIndex(of area: CGRect, in displays: [Display]) -> Int? {
	var best: (index: Int, area: CGFloat)?
	for display in displays {
		let overlap = display.bounds.intersection(area)
		guard !overlap.isNull else { continue }
		let size = overlap.width * overlap.height
		if size > 0, size > best?.area ?? 0 { best = (display.index, size) }
	}
	return best?.index
}

/// The Spaces holding a window, sorted; mask 7 is current, other and user Spaces.
func spaceIDs(window: Int) -> [UInt64] {
	let ids = spacesCopySpacesForWindows(spacesDefaultConnection(), 7, [window] as CFArray) as? [NSNumber] ?? []
	return ids.map(\.uint64Value).sorted()
}

/// Where windows sit: the active displays, each display's current Space, and whether it's asleep. Read once per listing.
struct WindowPlaces {
	private let displays: [Display]
	private let current: [CGDirectDisplayID: UInt64]

	init() {
		displays = activeDisplays()
		let spans = CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? Bool ?? false
		let raw = spacesCopyManagedDisplaySpaces(spacesDefaultConnection()) as? [[String: Any]] ?? []
		var current: [CGDirectDisplayID: UInt64] = [:]
		for entry in raw {
			guard let uuid = entry["Display Identifier"] as? String else { continue }
			let space = ((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
			// When Spaces span displays, WindowServer lists one shared entry for all of them.
			let shown = spans ? displays : WindowPlaces.display(for: uuid, in: displays).map { [$0] } ?? []
			for display in shown { current[display.id] = space }
		}
		self.current = current
	}

	private static func display(for uuid: String, in displays: [Display]) -> Display? {
		if uuid == "Main" { return displays.first(where: \.isMain) }
		return displays.first { display in
			guard let id = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue(),
			      let text = CFUUIDCreateString(nil, id) as String?
			else { return false }
			return text.caseInsensitiveCompare(uuid) == .orderedSame
		}
	}

	/// The display holding most of the window, its current Space and whether it sleeps; all nil when it's on no display.
	func place(_ bounds: CGRect) -> (index: Int?, space: UInt64?, asleep: Bool?) {
		guard let index = displayIndex(of: bounds, in: displays) else { return (nil, nil, nil) }
		let display = displays[index]
		return (index, current[display.id], CGDisplayIsAsleep(display.id) != 0)
	}

	func pointerDisplay(_ point: CGPoint) -> Int? {
		displays.first { $0.bounds.contains(point) }?.index
	}
}
