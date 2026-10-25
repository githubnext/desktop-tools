import DesktopProtocol

private let reinspect = "then inspect it again before acting."

/// Classifies one desktop_windows row, most fundamental cause first. Ported from src/availability.ts.
public func windowAvailability(_ window: JSON, sessionLocked: Bool, appHidden: Bool?) -> JSON {
	if sessionLocked {
		return .object([("state", "unavailable"), ("reason", "session_locked"),
		                ("hint", "The macOS GUI session is locked. Unlock the active user session, then observe the screen before retrying.")])
	}
	if window["observation_reason"]?.string == "open_save_panel_service" {
		return .object([("state", "unavailable"), ("reason", "open_save_panel_service"),
		                ("hint", "This window belongs to the service that draws another app's Open or Save panel, and to its sheets such as Go to Folder. Use the app that opened the panel: its desktop_windows lists the panel with the same title and bounds, which desktop_inspect and desktop_click reach in the background. To go to a folder or file, pass the app's target to desktop_dialog, then desktop_dialog_answer with path.")])
	}
	if window["is_minimized"]?.bool == true {
		return .object([("state", "unavailable"), ("reason", "minimized"),
		                ("hint", JSON("The window is minimized. Restore it with desktop_restore, using its target from desktop_windows, \(reinspect)"))])
	}
	if appHidden == true {
		return .object([("state", "unavailable"), ("reason", "app_hidden"),
		                ("hint", JSON("The app is hidden. Unhide it with desktop_unhide, \(reinspect)"))])
	}
	if window["display_asleep"]?.bool == true {
		return .object([("state", "unavailable"), ("reason", "display_asleep"),
		                ("hint", "The window's display is asleep, so nothing on it can be captured. Wake the display, then observe the screen before retrying.")])
	}
	let spaces = window["space_ids"]?.array ?? []
	if let current = window["display_current_space_id"], !current.isNull, !spaces.isEmpty, !spaces.contains(current) {
		let space = spaces[0].text
		return .object([("state", "unavailable"), ("reason", "other_space"), ("space_id", spaces[0]),
		                ("hint", JSON("The window is on Space \(space), not the current Space of its display. Switch with desktop_switch_space to space_id \(space), or bring the window forward with desktop_focus or its app with desktop_activate, which switch Spaces; \(reinspect)"))])
	}
	// JSON.stringify drops an absent display_index, so only an explicit null means "on no display".
	if window["display_index"]?.isNull == true, let bounds = window["bounds"],
	   (bounds["width"]?.number ?? 0) > 0, (bounds["height"]?.number ?? 0) > 0
	{
		return .object([("state", "unavailable"), ("reason", "off_screen"),
		                ("hint", JSON("The window's bounds are on no display. Move it onto one with desktop_move, choosing an origin inside a display's bounds from desktop_screen, \(reinspect)"))])
	}
	if window["is_on_screen"]?.bool == false {
		return .object([("state", "unavailable"), ("reason", "not_on_screen"),
		                ("hint", JSON("macOS reports the window off screen for no reason this listing can see. Bring it forward with desktop_focus, \(reinspect)"))])
	}
	if window["observation_capability"]?.string == "pixels_only" {
		return .object([("state", "limited"), ("reason", "accessibility_unavailable"),
		                ("cause", window["observation_reason"]?.string.map(JSON.string)),
		                ("hint", "The window is on screen, but Accessibility can't see it. A window that just opened or is loading, such as a web view, often fills in shortly: wait briefly and list windows again. Otherwise inspect with mode pixels, adding ocr true to read its text.")]
			.compactMap { key, value in value.map { (key, $0) } })
	}
	return .object([("state", "available"), ("reason", "visible")])
}
