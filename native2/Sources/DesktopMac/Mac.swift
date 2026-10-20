/// The only module that touches macOS: Accessibility, CoreGraphics, WindowServer Spaces and AppKit.
public enum Mac {}

import AppKit
import CoreGraphics

extension Mac {
	/// The process generation, or nil when the process is gone or unreadable.
	public static func generation(_ pid: pid_t) -> UInt64? { startIdentity(pid).value }

	/// One window's owner, bounds and title, read fresh from WindowServer.
	public static func window(_ id: Int) -> (pid: pid_t, bounds: CGRect, title: String)? {
		let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] ?? []
		guard let info = list.first, (info[kCGWindowNumber as String] as? NSNumber)?.intValue == id,
		      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
		      let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary)
		else { return nil }
		return (pid, bounds, info[kCGWindowName as String] as? String ?? "")
	}

	public static func appName(_ pid: pid_t) -> String? {
		NSRunningApplication(processIdentifier: pid).flatMap { $0.localizedName ?? $0.bundleIdentifier }
	}

	public static func displayIndex(_ bounds: CGRect) -> Int? { DesktopMac.displayIndex(of: bounds, in: activeDisplays()) }

	/// Pixels per point on the display holding most of `bounds`.
	public static func backingScale(_ bounds: CGRect) -> Double {
		let displays = activeDisplays()
		guard let index = DesktopMac.displayIndex(of: bounds, in: displays), let mode = CGDisplayCopyDisplayMode(displays[index].id),
		      mode.width > 0
		else { return 1 }
		return Double(mode.pixelWidth) / Double(mode.width)
	}
}
