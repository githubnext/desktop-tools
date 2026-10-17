import assert from "node:assert/strict";
import { test } from "node:test";
import { boundedElements } from "../dist/client.js";

const element = (id, role, label) => ({ id, role: "other", label, attributes: { role } });

test("a result too large keeps the containers an agent can scope into, in order", () => {
	// A long sidebar listed before the file list, as Finder reports it.
	const sidebar = Array.from({ length: 120 }, (_, n) => element(`elem_${n + 3}`, "AXRow", `place ${n}`));
	const list = [element("elem_200", "AXScrollArea", "scroll area"), element("elem_201", "AXOutline", "list view")];
	const rows = Array.from({ length: 40 }, (_, n) => element(`elem_${n + 202}`, "AXRow", `item ${n}`));
	const ui_elements = [element("elem_0", "AXWindow", "w"), element("elem_2", "AXOutline", "sidebar"), ...sidebar, ...list, ...rows];
	const result = JSON.parse(boundedElements({ ui_elements }, 8_000));
	const ids = result.ui_elements.map((e) => e.id);
	assert.equal(result.truncated, true);
	assert.equal(result.omitted, ui_elements.length - ids.length);
	assert.deepEqual(ids.slice(-2), ["elem_200", "elem_201"]);
	assert.deepEqual(ids.slice(0, 3), ["elem_0", "elem_2", "elem_3"]);
	assert.ok(!ids.includes("elem_202"));
});

test("a result that fits is unchanged", () => {
	const ui_elements = [element("elem_0", "AXWindow", "w"), element("elem_1", "AXButton", "OK")];
	assert.deepEqual(JSON.parse(boundedElements({ ui_elements })), { ui_elements });
});
