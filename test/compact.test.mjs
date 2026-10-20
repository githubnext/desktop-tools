import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { compactResult } from "../dist/compact.js";

const fixture = (name) => readFileSync(new URL(`fixtures/compact/${name}.json`, import.meta.url), "utf8");

// Results a model reads each cost about one token per three or four characters of JSON. These budgets hold a TextEdit
// document window, recorded from the native client, well under what the whole native result costs.
const BUDGETS = { "inspect-textedit": 2_400, "windows-textedit": 600 };

for (const [name, budget] of Object.entries(BUDGETS)) {
	test(`a compact ${name} result stays under ${budget} characters`, () => {
		const whole = fixture(name);
		const compact = compactResult(whole);
		assert.ok(compact.length <= budget, `${compact.length} characters`);
		assert.ok(compact.length < JSON.stringify(JSON.parse(whole)).length / 2);
	});
}

test("an inspection keeps what input needs and drops how it was produced", () => {
	const whole = JSON.parse(fixture("inspect-textedit"));
	const result = JSON.parse(compactResult(fixture("inspect-textedit")));
	for (const key of ["detection_metadata", "diagnostics", "timings", "coordinate_context", "target_receipt", "element_count"]) {
		assert.ok(!(key in result), key);
	}
	assert.equal(result.snapshot_id, whole.snapshot_id);
	assert.deepEqual(result.image, { width: whole.image.width, height: whole.image.height });
	assert.equal(result.ui_elements.length, whole.ui_elements.length);
	const area = result.ui_elements.find((element) => element.identifier === "First Text View");
	assert.deepEqual(area.bounds, [152, 105, 656, 384]);
	assert.equal(area.focused, true);
	assert.equal(area.settable, true);
	assert.equal(area.enabled, "unknown");
	assert.equal(area.kind, "text entry area");
	assert.equal(area.depth, 2);
	assert.ok(!("attributes" in area));
	const close = result.ui_elements.find((element) => element.label === "close button");
	assert.deepEqual(Object.keys(close), ["id", "role", "label", "bounds", "actionable", "depth"]);
	// A role Peekaboo calls "other" keeps its Accessibility role, which makes "scroll bar" redundant.
	const bar = result.ui_elements.find((element) => element.role === "AXScrollBar");
	assert.ok(bar && !("kind" in bar));
});

test("a window list counts the untitled off-screen strips instead of listing them", () => {
	const whole = JSON.parse(fixture("windows-textedit"));
	const result = JSON.parse(compactResult(fixture("windows-textedit")));
	assert.equal(result.windows.length, 1);
	assert.equal(result.hidden_windows, whole.windows.length - 1);
	const [row] = result.windows;
	const source = whole.windows.find((window) => window.window_id === row.target.window_id);
	assert.deepEqual(row.target, source.target);
	assert.equal(row.title, "note.txt");
	assert.deepEqual(row.availability, { state: "available", reason: "visible" });
	for (const key of ["window_id", "bounds", "is_minimized", "process_start_identity_decimal", "is_on_screen"]) {
		assert.ok(!(key in row), key);
	}
	const all = JSON.parse(compactResult(fixture("windows-textedit"), { allWindows: true }));
	assert.equal(all.windows.length, whole.windows.length);
	assert.ok(!("hidden_windows" in all));
});

test("a minimized, hidden or other-Space window is never counted as a strip", () => {
	const row = (id, extra) => ({
		window_id: id,
		window_title: "",
		is_on_screen: false,
		space_ids: [],
		target: { pid: 1, process_start_identity_decimal: "1", window_id: id, bounds: { x: 0, y: 0, width: 9, height: 9 }, is_minimized: false },
		availability: { state: "unavailable", reason: "not_on_screen" },
		...extra,
	});
	const windows = [
		row(1),
		row(2, { target: { ...row(2).target, is_minimized: true } }),
		row(3, { space_ids: [4] }),
		row(4, { is_on_screen: true, availability: { state: "available", reason: "visible" } }),
	];
	const result = JSON.parse(compactResult(JSON.stringify({ windows })));
	assert.deepEqual(result.windows.map((window) => window.target.window_id), [2, 3, 4]);
	assert.equal(result.hidden_windows, 1);
});

test("an app row keeps its target and only the states that are set or unknown", () => {
	const app = (extra) => ({
		name: "TextEdit",
		bundle_id: "com.apple.TextEdit",
		pid: 7,
		process_start_identity_decimal: "9",
		target: { pid: 7, process_start_identity_decimal: "9" },
		is_active: false,
		is_active_known: true,
		is_hidden: false,
		is_hidden_known: true,
		...extra,
	});
	const result = JSON.parse(compactResult(JSON.stringify({
		apps: [app(), app({ is_active: true }), app({ is_hidden_known: false })],
		system: { note: "Read when this inventory was taken.", session: { locked: false, on_console: true } },
	})));
	assert.deepEqual(result.apps[0], { name: "TextEdit", bundle_id: "com.apple.TextEdit", pid: 7, target: { pid: 7, process_start_identity_decimal: "9" } });
	assert.equal(result.apps[1].active, true);
	assert.equal(result.apps[2].hidden, "unknown");
	assert.deepEqual(result.system, { session: { on_console: true } });
});

test("an action keeps its outcome, and retry safety only when the outcome is unknown", () => {
	const native = { state: "unknown", retry_safety: "unsafe", effect: "unknown", dispatch_state: "dispatched" };
	const action = (outcome) => JSON.stringify({
		action: { action: "click", snapshot_id: "s", outcome, native_outcome: native, requires_fresh_observation: true, target_receipt: { pid: 1 } },
	});
	assert.deepEqual(JSON.parse(compactResult(action("completed"))), { action: { outcome: "completed" } });
	assert.deepEqual(JSON.parse(compactResult(action("unknown"))), { action: { outcome: "unknown", retry_safety: "unsafe" } });
	// A matched expectation records the native outcome it overrode.
	const expected = JSON.stringify({ action: { outcome: "completed", native_outcome: "unknown" } });
	assert.deepEqual(JSON.parse(compactResult(expected)), { action: { outcome: "completed", native_outcome: "unknown" } });
});
