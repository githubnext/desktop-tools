const reinspect = "then inspect it again before acting.";
/** Classifies one window from its desktop_windows row, most fundamental cause first. */
export function windowAvailability(window, session) {
    if (session.session_locked) {
        return {
            state: "unavailable",
            reason: "session_locked",
            hint: "The macOS GUI session is locked. Unlock the active user session, then observe the screen before retrying.",
        };
    }
    if (window.is_minimized) {
        return {
            state: "unavailable",
            reason: "minimized",
            hint: `The window is minimized. Restore it with desktop_restore, using its target from desktop_windows, ${reinspect}`,
        };
    }
    if (session.app_hidden) {
        return {
            state: "unavailable",
            reason: "app_hidden",
            hint: `The app is hidden. Unhide it with desktop_unhide, ${reinspect}`,
        };
    }
    if (window.display_asleep) {
        return {
            state: "unavailable",
            reason: "display_asleep",
            hint: "The window's display is asleep, so nothing on it can be captured. Wake the display, then observe the screen before retrying.",
        };
    }
    const spaces = window.space_ids ?? [];
    const current = window.display_current_space_id;
    if (spaces.length && current != null && !spaces.includes(current)) {
        return {
            state: "unavailable",
            reason: "other_space",
            space_id: spaces[0],
            hint: `The window is on Space ${spaces[0]}, not the current Space of its display. Switch with desktop_switch_space to space_id ${spaces[0]}, or bring the window forward with desktop_focus or its app with desktop_activate, which switch Spaces; ${reinspect}`,
        };
    }
    const bounds = window.bounds;
    if (window.display_index === null && bounds && bounds.width > 0 && bounds.height > 0) {
        return {
            state: "unavailable",
            reason: "off_screen",
            hint: `The window's bounds are on no display. Move it onto one with desktop_move, choosing an origin inside a display's bounds from desktop_screen, ${reinspect}`,
        };
    }
    if (window.is_on_screen === false) {
        return {
            state: "unavailable",
            reason: "not_on_screen",
            hint: `macOS reports the window off screen for no reason this listing can see. Bring it forward with desktop_focus, ${reinspect}`,
        };
    }
    if (window.observation_capability === "pixels_only") {
        return {
            state: "limited",
            reason: "accessibility_unavailable",
            ...(window.observation_reason ? { cause: window.observation_reason } : {}),
            hint: "The window is on screen, but Accessibility can't see it. A window that just opened or is loading, such as a web view, often fills in shortly: wait briefly and list windows again. Otherwise inspect with mode pixels, adding ocr true to read its text.",
        };
    }
    return { state: "available", reason: "visible" };
}
/**
 * Classifies a failed inspection, read or action from the window's row read afterwards. A window that looks
 * available but failed with an incomplete Accessibility read has a sparse tree, as on a web view's first load.
 */
export function failureAvailability(message, window, session) {
    if (!window) {
        if (session.session_locked)
            return windowAvailability({}, session);
        return {
            state: "unavailable",
            reason: "window_gone",
            hint: "The window is no longer in its app's window list; it may have closed. List desktop_windows again and choose a current window.",
        };
    }
    const availability = windowAvailability(window, session);
    if (availability.state !== "unavailable" && /incomplete|sparse/i.test(message)) {
        return {
            state: "limited",
            reason: "sparse_accessibility",
            hint: "The window is on screen on the current Space, but its Accessibility tree was incomplete, as often happens while a web view first loads. Wait a second or two and inspect again once; otherwise inspect with mode pixels, adding ocr true to read its text.",
        };
    }
    return availability;
}
