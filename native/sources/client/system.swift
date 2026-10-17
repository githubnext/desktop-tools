import AppKit
import Carbon
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

/// The focused element read waits this long at most, so a slow app never delays the inventory.
private let focusReadLimit: Duration = .milliseconds(300)

/// Desktop-wide state an agent reads before acting: where input would land, appearance, session and input.
struct SystemState: Encodable {
	let focus: SystemFocus
	let appearance: Appearance
	let session: Session
	let input: Input
	let menu_bar_autohides: Bool
	let dock_autohides: Bool
	let warnings: [String]
	let note = "Read when this inventory was taken. focus is where keyboard input to the frontmost app would land; element omits the control's value, so read text with desktop_read. Positions are global desktop points."
}

struct SystemFocus: Encodable {
	let pid: Int32?
	let bundle_id: String?
	let app_name: String?
	let window_id: Int?
	let element: FocusedElement?
}

struct FocusedElement: Encodable {
	let role: String
	let title: String?
	let identifier: String?
	let bounds: Bounds
	let window_id: Int?
}

struct Appearance: Encodable {
	let mode: String
	let switches_automatically: Bool
	let accent_color: String?
	let increase_contrast: Bool
	let reduce_motion: Bool
	let reduce_transparency: Bool
	let invert_colors: Bool
	let differentiate_without_color: Bool
}

struct Session: Encodable {
	let locked: Bool
	let on_console: Bool
	let screensaver_running: Bool
	let displays_asleep: Bool
	let secure_keyboard_entry: Bool
}

struct Input: Encodable {
	let keyboard_layout: KeyboardLayout?
	let pointer: Pointer?
}

struct KeyboardLayout: Encodable {
	let id: String
	let name: String?
}

struct Pointer: Encodable {
	let x: Double
	let y: Double
	let display_index: Int?
}

func systemState(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async -> SystemState {
	var warnings: [String] = []
	let workspace = NSWorkspace.shared
	let front = workspace.frontmostApplication
	let pid = front?.processIdentifier
	let window = pid.flatMap { pid in
		normalWindows([.optionOnScreenOnly, .excludeDesktopElements]).first { $0.pid == pid }?.id
	}
	var element: FocusedElement?
	if let pid {
		if (handshake.enabledOperations ?? handshake.supportedOperations).contains(.getFocusedElement) {
			switch await focusedElement(client, pid: pid) {
			case let .read(info):
				element = info.map {
					FocusedElement(
						role: $0.role, title: $0.title, identifier: $0.identifier, bounds: Bounds($0.frame),
						window_id: $0.windowID
					)
				}
			case .timedOut:
				warnings.append("The focused element read took longer than 300 ms, so focus.element is unknown.")
			case .failed:
				warnings.append("The focused element could not be read through Accessibility, so focus.element is unknown.")
			}
		} else {
			warnings.append("This desktop runtime does not read the focused element; update it to see focus.element.")
		}
	}
	let session = CGSessionCopyCurrentDictionary() as NSDictionary?
	let displays = (try? activeDisplays()) ?? []
	let pointer = CGEvent(source: nil).map(\.location).map { point in
		Pointer(
			x: point.x, y: point.y,
			display_index: displays.first { rect($0.bounds).contains(point) }?.index
		)
	}
	let defaults = UserDefaults.standard
	let dark = await MainActor.run {
		NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}
	var asleep = false
	var count: UInt32 = 0
	var ids = [CGDirectDisplayID](repeating: 0, count: 16)
	if CGGetOnlineDisplayList(16, &ids, &count) == .success, count > 0 {
		asleep = ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
	}
	return SystemState(
		focus: SystemFocus(
			pid: pid, bundle_id: front?.bundleIdentifier, app_name: front?.localizedName,
			// A login or full-screen panel isn't a normal-level window; its focused element still names it.
			window_id: window ?? element?.window_id,
			element: element
		),
		appearance: Appearance(
			mode: dark ? "dark" : "light",
			switches_automatically: defaults.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically"),
			accent_color: accentColor(defaults.object(forKey: "AppleAccentColor") as? Int),
			increase_contrast: workspace.accessibilityDisplayShouldIncreaseContrast,
			reduce_motion: workspace.accessibilityDisplayShouldReduceMotion,
			reduce_transparency: workspace.accessibilityDisplayShouldReduceTransparency,
			invert_colors: workspace.accessibilityDisplayShouldInvertColors,
			differentiate_without_color: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
		),
		session: Session(
			locked: session?["CGSSessionScreenIsLocked"] as? Bool == true,
			on_console: session?["kCGSSessionOnConsoleKey"] as? Bool ?? false,
			screensaver_running: workspace.runningApplications.contains {
				$0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
			},
			displays_asleep: asleep,
			secure_keyboard_entry: IsSecureEventInputEnabled()
		),
		input: Input(keyboard_layout: keyboardLayout(), pointer: pointer),
		menu_bar_autohides: defaults.bool(forKey: "_HIHideMenuBar"),
		dock_autohides: UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false,
		warnings: warnings
	)
}

private enum FocusRead {
	case read(UIFocusInfo?)
	case timedOut
	case failed
}

/// Races the host's focused element read against its own short limit; a late answer is discarded.
private func focusedElement(_ client: PeekabooBridgeClient, pid: Int32) async -> FocusRead {
	await withTaskGroup(of: FocusRead.self) { group in
		group.addTask {
			do { return .read(try await client.getFocusedElement(targetProcessIdentifier: pid)) } catch { return .failed }
		}
		group.addTask {
			try? await Task.sleep(for: focusReadLimit)
			return .timedOut
		}
		let first = await group.next() ?? .failed
		group.cancelAll()
		return first
	}
}

/// System Settings' accent colors by their stored index; no value means the multicolor default.
private func accentColor(_ index: Int?) -> String? {
	guard let index else { return "multicolor" }
	return [-1: "graphite", 0: "red", 1: "orange", 2: "yellow", 3: "green", 4: "blue", 5: "purple", 6: "pink"][index]
}

private func keyboardLayout() -> KeyboardLayout? {
	guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
		let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
	else { return nil }
	let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
	return KeyboardLayout(
		id: Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String,
		name: name.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
	)
}
