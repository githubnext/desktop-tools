import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { notificationAction, readNotifications } from "../dist/notifications.js";

const fixture = JSON.parse(readFileSync(new URL("fixtures/notifications.json", import.meta.url), "utf8"));
const signal = new AbortController().signal;

/** Notification Center as pid 9 with one shown window; `perform` records native requests. */
function center({ outcome = "completed", closes = true, alerts = [] } = {}) {
	const state = { elements: fixture.window, performed: [] };
	const io = {
		async observe(request) {
			if (request.op === "apps") {
				const apps = request.query === "com.apple.notificationcenterui"
					? [{ pid: 9, bundle_id: request.query }]
					: request.query === "com.apple.UserNotificationCenter" && alerts.length
					? [{ pid: 7, bundle_id: request.query }]
					: [];
				return { text: JSON.stringify({ apps, inventory_completeness: "complete" }) };
			}
			if (request.op === "windows") {
				const windows = request.pid === 7
					? alerts
					: [{ window_id: 5, is_on_screen: true }, { window_id: 6, is_on_screen: false }];
				return { text: JSON.stringify({ windows }) };
			}
			assert.deepEqual(request, { op: "inspect", pid: 9, window: 5 });
			return { text: JSON.stringify({ snapshot_id: "S1", ui_elements: state.elements }) };
		},
		async perform(input, _signal, onDispatch) {
			state.performed.push(input);
			if (outcome === "refused") {
				return { outcome, error: { code: "SNAPSHOT_STALE", message: "The snapshot is no longer available." } };
			}
			onDispatch();
			if (closes) state.elements = fixture.after_close;
			return { outcome };
		},
	};
	return { io, state };
}

test("lists banners, stacks and alerts with their fields and listed actions", async () => {
	const { io } = center();
	const read = await readNotifications(io, signal);
	assert.deepEqual(read.notifications.map(({ id, kind, stack }) => [id, kind, stack]), [
		["S1/e1", "AXNotificationCenterBanner", false],
		["S1/e4", "AXNotificationCenterAlertStack", true],
		["S1/e5", "AXNotificationCenterAlert", false],
	]);
	const [banner, group, alert] = read.notifications;
	assert.deepEqual(
		[banner.app, banner.title, banner.subtitle, banner.body, banner.fields_from],
		["Messages", "Ada", null, "See you at 6", "order"],
	);
	assert.deepEqual(banner.actions, ["open", "Close", "Show", "Reply"]);
	// A stack's texts belong to the notifications inside it.
	assert.deepEqual(group.texts, []);
	assert.deepEqual(group.actions, ["open", "Clear All"]);
	assert.deepEqual(
		[alert.app, alert.title, alert.subtitle, alert.body, alert.time, alert.fields_from],
		["Mail", "Bob", "Invoice", "Due Friday", "5m ago", "identifiers"],
	);
	assert.deepEqual(read.notification_center.shown_windows.map(({ window_id }) => window_id), [5]);
});

test("system alerts are listed for desktop_dialog, never inspected", async () => {
	const { io } = center({ alerts: [{ window_id: 70, is_on_screen: true, window_title: "", target: { pid: 7 } }] });
	const read = await readNotifications(io, signal);
	assert.deepEqual(read.system_alerts, [
		{ host: "com.apple.UserNotificationCenter", pid: 7, window_id: 70, title: null, target: { pid: 7 } },
	]);
});

test("close runs the listed Close custom action and completes once the notification is gone", async () => {
	const { io, state } = center();
	await readNotifications(io, signal);
	const { outcome, data } = await notificationAction(io, { id: "S1/e5", action: "close" }, signal);
	assert.deepEqual(state.performed, [
		{ op: "element-action", snapshot: "S1", element: "e5", action: "AXCustomAction:Close" },
	]);
	assert.equal(outcome, "completed");
	assert.equal(data.notification_gone, true);
});

test("open is the default click, and a notification still shown is unknown", async () => {
	const { io, state } = center({ closes: false });
	await readNotifications(io, signal);
	const { outcome, data } = await notificationAction(io, { id: "S1/e1", action: "open" }, signal);
	assert.deepEqual(state.performed, [{ op: "click", snapshot: "S1", element: "e1" }]);
	assert.equal(outcome, "unknown");
	assert.equal(data.notification_gone, false);
});

test("a stale notification is refused as gone, and malformed requests send nothing", async () => {
	const { io, state } = center({ outcome: "refused" });
	await readNotifications(io, signal);
	const { outcome, data } = await notificationAction(io, { id: "S1/e1", action: "Reply" }, signal);
	assert.equal(outcome, "refused");
	assert.match(data.message, /Notification gone; read again/);
	for (const request of [{ id: "S1", action: "close" }, { id: "S1/e1", action: "Close\nTarget:0x0" }]) {
		await assert.rejects(notificationAction(io, request, signal));
	}
	assert.equal(state.performed.length, 1);
});
