import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";
import { EXPECT_MAX_MS, expectAfter, validateExpect } from "../dist/wait.js";

/** A Mac whose frontmost app and one window's text the action changes; `acts` counts input. */
function mac({ outcome = "unknown", front = 1, after = 2, text = "before", typed = "after" } = {}) {
	const state = { front, text, acts: 0, reads: 0 };
	const reads = {
		async observe(request) {
			state.reads++;
			assert.equal(request.op, "apps");
			const apps = [1, 2].map((pid) => ({ pid, bundle_id: `app.${pid}`, is_active_known: true, is_active: pid === state.front }));
			return { text: JSON.stringify({ apps, inventory_completeness: "complete" }) };
		},
		async elements(input) {
			state.reads++;
			assert.deepEqual(input, { pid: 3, window: 4, text: true });
			return { text: state.text, truncated: false, truncation: [], window_title: "Notes" };
		},
	};
	const act = async () => {
		state.acts++;
		state.front = after;
		state.text = typed;
		return { text: JSON.stringify({ action: { outcome, receiver: "window_focus" } }), outcome, isError: outcome !== "completed" };
	};
	return { state, reads, act };
}

const frontmost = (pid, timeout_ms = 400) => validateExpect({ until: "app_frontmost", pid, timeout_ms });

test("an unknown outcome becomes completed when the expected condition holds after input", async () => {
	const { state, reads, act } = mac();
	const result = await expectAfter(reads, frontmost(2), act);
	const data = JSON.parse(result.text);
	assert.equal(result.outcome, "completed");
	assert.equal(result.isError, false);
	assert.equal(data.action.outcome, "completed");
	assert.equal(data.action.native_outcome, "unknown");
	assert.equal(data.expectation.status, "matched");
	assert.equal(data.expectation.match.apps.find((app) => app.pid === 2).is_active, true);
	assert.equal(state.acts, 1);
});

test("a condition that never holds leaves the outcome unknown with the last observation, and input isn't repeated", async () => {
	const { state, reads, act } = mac({ after: 1 });
	const result = await expectAfter(reads, frontmost(2, 300), act);
	const data = JSON.parse(result.text);
	assert.equal(result.outcome, "unknown");
	assert.equal(data.action.outcome, "unknown");
	assert.equal(data.expectation.status, "timed_out");
	assert.ok(data.expectation.last_observation.apps);
	assert.ok(data.expectation.polls >= 1);
	assert.equal(state.acts, 1);
});

test("a condition that already holds is refused before input", async () => {
	const { state, reads, act } = mac({ front: 2 });
	const result = await expectAfter(reads, frontmost(2), act);
	const data = JSON.parse(result.text);
	assert.equal(result.outcome, "refused");
	assert.match(data.action.reason, /already holds/);
	assert.equal(data.expectation.status, "refused");
	assert.equal(state.acts, 0);
});

test("window_appears skips a window ordered out on the current Space, but not one on another Space", async () => {
	const panel = (row) => ({ window_id: 34, window_title: "Spotlight", is_minimized: false, display_current_space_id: 1, ...row });
	const scenario = async (before, hidden = false) => {
		let row = before;
		const reads = {
			async observe(request) {
				assert.deepEqual(request, { op: "windows", pid: 5 });
				return { text: JSON.stringify({ windows: [panel(row)], inventory_completeness: "complete", app_hidden: hidden }) };
			},
		};
		const act = async () => {
			row = { is_on_screen: true, space_ids: [1] };
			return { text: JSON.stringify({ action: { outcome: "unknown" } }), outcome: "unknown", isError: true };
		};
		const request = validateExpect({ until: "window_appears", pid: 5, title: "Spotlight", timeout_ms: 300 });
		return (await expectAfter(reads, request, act)).outcome;
	};
	assert.equal(await scenario({ is_on_screen: false, space_ids: [1] }), "completed");
	assert.equal(await scenario({ is_on_screen: false, space_ids: [] }), "completed");
	assert.equal(await scenario({ is_on_screen: false, space_ids: [2] }), "refused");
	assert.equal(await scenario({ is_on_screen: false, space_ids: [1] }, true), "refused");
});

test("completed and refused outcomes come back as they are, without polling", async () => {
	for (const outcome of ["completed", "refused"]) {
		const { state, reads, act } = mac({ outcome });
		const result = await expectAfter(reads, frontmost(2), act);
		assert.equal(result.outcome, outcome);
		assert.equal(JSON.parse(result.text).expectation, undefined);
		// Only the read before input.
		assert.equal(state.reads, 1);
	}
});

test("text_changes compares with the text read before input", async () => {
	const { state, reads, act } = mac();
	const result = await expectAfter(reads, validateExpect({ until: "text_changes", pid: 3, window: 4 }), act);
	const data = JSON.parse(result.text);
	assert.equal(result.outcome, "completed");
	assert.equal(data.expectation.match.before, "before");
	assert.equal(data.expectation.match.text, "after");
	assert.equal(state.acts, 1);
});

test("a condition that can't be read before input refuses the action", async () => {
	const { state, act } = mac();
	const reads = {
		observe: async () => ({ text: "{}" }),
		elements: async () => {
			throw new Error("The window is gone.");
		},
	};
	const result = await expectAfter(reads, validateExpect({ until: "text_contains", pid: 3, window: 4, text: "x" }), act);
	assert.equal(result.outcome, "refused");
	assert.match(JSON.parse(result.text).action.reason, /couldn't be read reliably/);
	assert.equal(state.acts, 0);
});

test("expect takes desktop_wait's arguments with a shorter timeout", () => {
	assert.throws(() => validateExpect({ op: "wait", until: "app_running", pid: 1 }), /without op/);
	assert.throws(() => validateExpect({ until: "app_running", pid: 1, timeout_ms: EXPECT_MAX_MS + 1 }), /timeout_ms/);
	assert.throws(() => validateExpect({ until: "app_running", pid: 1, window: 2 }), /doesn't use window/);
	assert.throws(() => validateExpect("app_running"), /object/);
	assert.equal(validateExpect({ until: "element_appears", pid: 1, window: 2, element: { role: "AXMenu", title: "Edit" } }).op, "wait");
});

test("click, key, system_key, drag and insert take expect; other actions don't", () => {
	const tools = desktopTools({ place: "this Mac", app: "Desktop Tools" });
	const taking = tools.filter((tool) => tool.parameters.properties?.expect).map((tool) => tool.name).sort();
	assert.deepEqual(taking, ["desktop_click", "desktop_drag", "desktop_insert", "desktop_key", "desktop_system_key"]);
	const expect = tools.find((tool) => tool.name === "desktop_click").parameters.properties.expect;
	assert.equal(expect.properties.timeout_ms.maximum, EXPECT_MAX_MS);
	assert.ok(expect.properties.until.enum.length > 10);
});

const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

test("expect on an action that doesn't take it, or with a bad condition, is refused before input", macOS, async () => {
	const scroll = await desktop({ op: "scroll", snapshot: "S", element: "e", direction: "down", amount: 1, expect: { until: "app_running", pid: 1 } }, signal);
	assert.equal(scroll.outcome, "refused");
	assert.match(scroll.data.action.reason, /scroll doesn't take expect/);
	const click = await desktop({ op: "click", snapshot: "S", element: "e", expect: { until: "app_running", pid: 1, timeout_ms: 20_000 } }, signal);
	assert.equal(click.outcome, "refused");
	assert.match(click.data.action.reason, /timeout_ms/);
});

test("app conditions find a bundle ID that a long, cut app list would drop, and a cut list never proves a quit", async () => {
	// Like desktop_apps with many apps running: the full list is cut to fit, and a query matches natively.
	const reads = {
		async observe(request) {
			assert.equal(request.op, "apps");
			const apps = request.query === "app.target"
				? [{ pid: 9, bundle_id: "app.target", is_active_known: true, is_active: true }]
				: [{ pid: 1, bundle_id: "app.other", is_active_known: true, is_active: false }];
			return { text: JSON.stringify({ apps, inventory_completeness: "complete", truncated: request.query === undefined }) };
		},
	};
	let acts = 0;
	const act = async () => {
		acts++;
		return { text: JSON.stringify({ action: { outcome: "unknown" } }), outcome: "unknown", isError: true };
	};
	const held = await expectAfter(reads, validateExpect({ until: "app_frontmost", bundle_id: "app.target" }), act);
	assert.equal(held.outcome, "refused");
	assert.equal(acts, 0);
	const quit = await expectAfter(reads, validateExpect({ until: "app_quit", pid: 9, timeout_ms: 300 }), act);
	assert.equal(quit.outcome, "unknown");
	assert.notEqual(JSON.parse(quit.text).expectation.status, "matched");
});
