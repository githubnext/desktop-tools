import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { setCell } from "../dist/cell.js";

const fixtures = JSON.parse(readFileSync(new URL("fixtures/tables.json", import.meta.url), "utf8"));
const signal = new AbortController().signal;
const request = { op: "set-cell", pid: 10, window: 20, snapshot: "S1", table: "elem_20" };

/** Each table read returns the next element list; each action returns the given outcome. */
function io(reads, outcome = "completed") {
	const calls = { tables: [], actions: [] };
	return {
		calls,
		table: async (input) => {
			calls.tables.push(input);
			return { elements: reads[calls.tables.length - 1] };
		},
		act: async (action) => {
			calls.actions.push(action);
			return { text: JSON.stringify({ snapshot_id: "S2", action: { outcome } }), outcome };
		},
	};
}

/** The Finder fixture with some element values replaced. */
function finder(values) {
	return fixtures.finder.map((element) => element.id in values ? { ...element, value: values[element.id] } : element);
}

const parse = (result) => JSON.parse(result.text);

test("a text cell is typed through its field and confirmed by reading the table again", async () => {
	const fake = io([fixtures.finder, finder({ elem_35: "Notes.md" })]);
	const result = await setCell(fake, { ...request, row: "elem_32", column: "Name", value: "Notes.md" }, signal);
	assert.equal(result.outcome, "completed");
	assert.deepEqual(fake.calls.actions, [{ op: "type", snapshot: "S1", element: "elem_35", text: "Notes.md" }]);
	assert.deepEqual(fake.calls.tables[1], { pid: 10, window: 20, snapshot: "S1", element: "elem_20" });
	const data = parse(result);
	assert.equal(data.snapshot_id, "S2");
	assert.deepEqual(data.cell, {
		row: 1,
		column: 0,
		column_title: "Name",
		before: "Notes.txt",
		control: { role: "AXTextField", route: "type" },
		after: "Notes.md",
		readback: "matched",
	});
});

test("a cell that doesn't read back the value, or whose row changed, is unknown", async () => {
	const same = io([fixtures.finder, fixtures.finder]);
	const differs = await setCell(same, { ...request, row: "elem_32", column: 0, value: "Notes.md" }, signal);
	assert.equal(differs.outcome, "unknown");
	assert.equal(parse(differs).cell.readback, "differs");
	assert.equal(parse(differs).action.error.code, "CELL_UNVERIFIED");

	// After a rename, Finder can re-sort, so the row at that position is another file.
	const sorted = io([fixtures.finder, finder({ elem_35: "Notes.md", elem_37: "Today at 08:00" })]);
	const moved = await setCell(sorted, { ...request, row: "elem_32", column: "Name", value: "Notes.md" }, signal);
	assert.equal(moved.outcome, "unknown");
	assert.equal(parse(moved).cell.readback, "row_changed");

	const failing = io([fixtures.finder]);
	const unreadable = await setCell(failing, { ...request, row: "elem_32", column: "Name", value: "Notes.md" }, signal);
	assert.equal(unreadable.outcome, "unknown");
	assert.equal(parse(unreadable).cell.readback, "unreadable");
});

test("a refused or unknown write keeps its outcome", async () => {
	const refusedWrite = io([fixtures.finder], "refused");
	const refused = await setCell(refusedWrite, { ...request, row: "elem_32", column: "Name", value: "x" }, signal);
	assert.equal(refused.outcome, "refused");
	assert.equal(refusedWrite.calls.tables.length, 1);

	const unknownWrite = io([fixtures.finder, finder({ elem_35: "x" })], "unknown");
	const unknown = await setCell(unknownWrite, { ...request, row: "elem_32", column: "Name", value: "x" }, signal);
	assert.equal(unknown.outcome, "unknown");
	assert.equal(parse(unknown).cell.readback, "matched");
});

test("cells without a control, unknown columns and rows are refused before any input", async () => {
	const numbers = { ...request, table: "elem_40" };
	const cases = [
		[fixtures.numbers, { ...numbers, row: "elem_45", column: 1, value: "4" }, /no editable control/],
		[fixtures.numbers, { ...numbers, row: "elem_45", column: "Qty", value: "4" }, /no column titles/],
		[fixtures.finder, { ...request, row: "elem_32", column: "Title", value: "x" }, /"Name","Date Modified"/],
		[fixtures.finder, { ...request, row: "elem_32", column: 7, value: "x" }, /4 cells/],
		[fixtures.finder, { ...request, row: "elem_35", column: 0, value: "x" }, /not a row/],
		[fixtures.finder, { ...request, row: "elem_32", column: 0, value: true }, /text control/],
		[fixtures.finder, { ...request, row: "elem_32", column: 0, value: 1e400 }, /finite number/],
	];
	for (const [elements, input, reason] of cases) {
		const fake = io([elements]);
		const result = await setCell(fake, input, signal);
		assert.equal(result.outcome, "refused");
		assert.match(parse(result).action.reason, reason);
		assert.equal(fake.calls.actions.length, 0);
	}
	const unstored = io([fixtures.finder.map((element) => element.id === "elem_35" ? { ...element, id: null } : element)]);
	const result = await setCell(unstored, { ...request, row: "elem_32", column: 0, value: "x" }, signal);
	assert.equal(parse(result).action.code, "CELL_NOT_IN_SNAPSHOT");
});

test("a checkbox cell is set through set_value and its value read back", async () => {
	const grid = (value) => [
		{ id: "elem_1", role: "AXTable", depth: 0, bounds: { x: 0, y: 0, width: 200, height: 40 } },
		{ id: "elem_2", role: "AXRow", depth: 1, bounds: { x: 0, y: 0, width: 200, height: 20 } },
		{ id: "elem_3", role: "AXCell", depth: 2, bounds: { x: 0, y: 0, width: 100, height: 20 } },
		{ id: "elem_4", role: "AXStaticText", depth: 3, value: "Wi-Fi", bounds: { x: 0, y: 0, width: 100, height: 20 } },
		{ id: "elem_5", role: "AXCell", depth: 2, bounds: { x: 100, y: 0, width: 100, height: 20 } },
		{ id: "elem_6", role: "AXCheckBox", depth: 3, value, bounds: { x: 100, y: 0, width: 20, height: 20 } },
	];
	const fake = io([grid("0"), grid("1")]);
	const result = await setCell(fake, { ...request, table: "elem_1", row: "elem_2", column: 1, value: true }, signal);
	assert.equal(result.outcome, "completed");
	assert.deepEqual(fake.calls.actions, [{ op: "set-value", snapshot: "S1", element: "elem_6", value: true }]);

	const ignored = io([grid("0"), grid("0")]);
	const unchanged = await setCell(ignored, { ...request, table: "elem_1", row: "elem_2", column: 1, value: true }, signal);
	assert.equal(unchanged.outcome, "unknown");
});
