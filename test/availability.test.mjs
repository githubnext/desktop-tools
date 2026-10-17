import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { failureAvailability, windowAvailability } from "../dist/availability.js";

const fixture = JSON.parse(readFileSync(new URL("fixtures/windows.json", import.meta.url), "utf8"));
const { rows, session } = fixture;

test("windows on screen on their display's current Space are available", () => {
	for (const name of ["visible", "all_spaces", "other_display_current"]) {
		assert.deepEqual(windowAvailability(rows[name], session), { state: "available", reason: "visible" }, name);
	}
});

test("a window on another Space names that Space for desktop_switch_space", () => {
	const availability = windowAvailability(rows.other_space, session);
	assert.equal(availability.state, "unavailable");
	assert.equal(availability.reason, "other_space");
	assert.equal(availability.space_id, 5);
	assert.match(availability.hint, /desktop_switch_space to space_id 5/);
	assert.match(availability.hint, /desktop_focus/);
});

test("minimized windows and hidden apps point to restore and unhide", () => {
	const minimized = windowAvailability(rows.minimized, session);
	assert.equal(minimized.reason, "minimized");
	assert.match(minimized.hint, /desktop_restore, using its target from desktop_windows/);
	const hidden = windowAvailability(rows.visible, { ...session, app_hidden: true });
	assert.equal(hidden.reason, "app_hidden");
	assert.match(hidden.hint, /desktop_unhide/);
});

test("a locked session or sleeping display outranks every window state", () => {
	for (const row of Object.values(rows)) {
		assert.equal(windowAvailability(row, { ...session, session_locked: true }).reason, "session_locked");
	}
	assert.equal(windowAvailability(rows.asleep, session).reason, "display_asleep");
});

test("bounds on no display point to desktop_move", () => {
	const availability = windowAvailability(rows.off_screen, session);
	assert.equal(availability.reason, "off_screen");
	assert.match(availability.hint, /desktop_move/);
});

test("an on-screen window Accessibility can't see is limited, with pixels as the way in", () => {
	const availability = windowAvailability(rows.no_accessibility, session);
	assert.equal(availability.state, "limited");
	assert.equal(availability.reason, "accessibility_unavailable");
	assert.equal(availability.cause, "no_matching_accessibility_window");
	assert.match(availability.hint, /mode pixels/);
});

test("an off-screen window with no known cause says so", () => {
	assert.equal(windowAvailability(rows.unexplained_off_screen, session).reason, "not_on_screen");
});

test("an incomplete Accessibility read of a visible window is a sparse tree", () => {
	const message = "Warning: AX tree incomplete at incomplete accessibility read";
	for (const name of ["visible", "no_accessibility"]) {
		const availability = failureAvailability(message, rows[name], session);
		assert.equal(availability.reason, "sparse_accessibility", name);
		assert.match(availability.hint, /mode pixels/);
	}
	// An unavailable window keeps its own cause rather than blaming the tree.
	assert.equal(failureAvailability(message, rows.other_space, session).reason, "other_space");
	assert.equal(failureAvailability("Snapshot is stale", rows.visible, session).reason, "visible");
});

test("a window missing from the listing is gone, unless the session is locked", () => {
	assert.equal(failureAvailability("", undefined, session).reason, "window_gone");
	assert.equal(failureAvailability("", undefined, { session_locked: true }).reason, "session_locked");
});
