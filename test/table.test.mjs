import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { buildTable, TableError } from "../dist/table.js";

const fixtures = JSON.parse(readFileSync(new URL("fixtures/tables.json", import.meta.url), "utf8"));

test("a Finder list reads its header buttons, outline depth, expansion and selection", () => {
	const table = buildTable(fixtures.finder);
	assert.deepEqual(table.table, { role: "AXOutline", label: "list view", element: "elem_21" });
	assert.deepEqual(table.columns, ["Name", "Date Modified", "Size", "Kind"]);
	assert.equal(table.row_count, 3);
	assert.deepEqual(table.rows[0], {
		index: 0,
		element: "elem_22",
		cells: ["Documents", "Today at 09:12", "--", "Folder"],
		depth: 0,
		expanded: true,
	});
	assert.deepEqual(table.rows[1], {
		index: 1,
		element: "elem_32",
		cells: ["Notes.txt", "Yesterday at 17:40", "2 KB", "Plain Text"],
		depth: 1,
		selected: true,
	});
	assert.equal(table.rows[2].expanded, false);
	assert.deepEqual(table.truncation, []);
});

test("labels that only repeat the role description are not cell text or column titles", () => {
	// Finder on macOS 27 labels unnamed cells, columns and icons with their role description.
	const table = buildTable(fixtures.finderRoleLabels);
	assert.deepEqual(table.columns, ["Name", "Date Modified", "Size", "Kind"]);
	assert.deepEqual(table.rows.map((row) => row.cells), [
		["item-01.txt", "Today at 10:19 AM", "7 bytes", "Plain Text"],
		["item-02.txt", "Today at 10:19 AM", "7 bytes", "Plain Text"],
		["sub-folder", "Today at 10:19 AM", "--", "Folder"],
	]);
	assert.equal(table.rows[2].expanded, false);
	assert.equal(table.table.label, "list view");
});

test("a Numbers table without header titles keeps every row, and an empty cell is empty", () => {
	const table = buildTable(fixtures.numbers);
	assert.equal(table.columns, null);
	assert.deepEqual(table.rows.map((row) => row.cells), [["Item", "Qty", "Price"], ["Apples", "3", "1.20"], ["Pears", "5", ""]]);
	assert.ok(table.rows.every((row) => !("depth" in row)));
});

test("a web table inside a scoped web area takes its header row as columns", () => {
	const table = buildTable(fixtures.web);
	assert.equal(table.table.element, "elem_62");
	assert.equal(table.tables_in_scope, 1);
	assert.deepEqual(table.columns, ["Plan", "Price"]);
	assert.deepEqual(table.rows.map((row) => [row.element, row.cells]), [
		["elem_68", ["Basic", "$5"]],
		[null, ["Pro", "$20 per month, billed yearly"]],
	]);
	// Rows keep their place in the whole table, after the header row.
	assert.deepEqual(table.rows.map((row) => row.index), [0, 1]);
});

test("a web table whose header cells are plain cells, as in Safari on macOS 27, still takes them as columns", () => {
	const web = structuredClone(fixtures.web);
	for (const element of web) {
		if (/header/i.test(element.role_description ?? "")) {
			element.role_description = "cell";
			element.column_header = true;
		}
	}
	assert.ok(web.some((element) => element.column_header));
	const table = buildTable(web);
	assert.deepEqual(table.columns, ["Plan", "Price"]);
	assert.deepEqual(table.rows.map((row) => row.cells[0]), ["Basic", "Pro"]);
});

test("pages are bounded by row_offset and max_rows", () => {
	const table = buildTable(fixtures.finder, { rowOffset: 1, maxRows: 1 });
	assert.equal(table.row_count, 3);
	assert.equal(table.row_offset, 1);
	assert.deepEqual(table.rows.map((row) => row.index), [1]);
	assert.deepEqual(table.truncation, ["row_limit"]);
	assert.deepEqual(buildTable(fixtures.finder, { rowOffset: 2, maxRows: 1 }).truncation, []);
});

test("long cells, wide rows and big pages are cut and say so", () => {
	const elements = [{ id: "t", role: "AXTable", depth: 0, bounds: { x: 0, y: 0, width: 100, height: 100 } }];
	for (let row = 0; row < 3; row++) {
		elements.push({ id: `r${row}`, role: "AXRow", depth: 1, bounds: { x: 0, y: row * 10, width: 100, height: 10 } });
		for (let cell = 0; cell < 70; cell++) {
			elements.push({
				id: null,
				role: "AXCell",
				depth: 2,
				value: "x".repeat(cell === 0 ? 300 : 1),
				bounds: { x: cell, y: row * 10, width: 1, height: 10 },
			});
		}
	}
	const table = buildTable(elements);
	assert.equal(table.rows[0].cells.length, 64);
	assert.equal(table.rows[0].cells[0].length, 256);
	assert.deepEqual(table.truncation.sort(), ["cell_text_limit", "column_limit"]);
	const big = [elements[0]];
	for (let row = 0; row < 500; row++) {
		big.push({ id: null, role: "AXRow", depth: 1, bounds: { x: 0, y: row, width: 100, height: 1 } });
		big.push({ id: null, role: "AXCell", depth: 2, value: "y".repeat(250), bounds: { x: 0, y: row, width: 1, height: 1 } });
	}
	const page = buildTable(big, { maxRows: 500 });
	assert.ok(page.rows.length < 500 && page.rows.length > 300);
	assert.deepEqual(page.truncation, ["text_limit"]);
});

test("a scope without a table is refused", () => {
	assert.throws(
		() => buildTable([{ id: "a", role: "AXGroup", depth: 0, bounds: { x: 0, y: 0, width: 1, height: 1 } }]),
		TableError,
	);
});

const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

test("a table read needs a scope and bounded paging", macOS, async () => {
	const scope = { snapshot: "S1", element: "elem_1" };
	const refused = (request) =>
		assert.rejects(desktop({ op: "read", pid: 1, window: 2, ...request }, signal));
	await refused({ table: true });
	await refused({ max_rows: 5, scope });
	await refused({ table: true, scope, max_rows: 501 });
	await refused({ table: true, scope, row_offset: -1 });
	await refused({ table: true, scope, row_offset: 0.5 });
});
