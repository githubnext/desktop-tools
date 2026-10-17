import type { DesktopAction, DesktopOutcome, DesktopRequest, DesktopResult } from "./protocol.js";
import { locateCell, type TableCell, type TableElement, TableError } from "./table.js";

type Json = Record<string, unknown>;
type SetCell = Extract<DesktopRequest, { op: "set-cell" }>;

export type CellIO = {
	/** One native table read of the scope element in the snapshot. */
	table(input: { pid: number; window: number; snapshot: string; element: string }, signal: AbortSignal): Promise<Json>;
	/** One desktop action, followed by its fresh observation. */
	act(request: DesktopAction, signal: AbortSignal): Promise<DesktopResult>;
};

const MAX_ID = 600;
const MAX_VALUE = 8192;

function refused(reason: string, extra: Json = {}): DesktopResult {
	return {
		text: JSON.stringify({ action: { outcome: "refused", reason, message: "No input was sent.", ...extra } }),
		outcome: "refused",
		isError: true,
	};
}

function validate(request: SetCell) {
	for (const [name, value] of [["pid", request.pid], ["window", request.window]] as const) {
		if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Pass the window's ${name} from desktop_windows.`);
	}
	for (const [name, value] of [["snapshot", request.snapshot], ["table", request.table], ["row", request.row]] as const) {
		if (typeof value !== "string" || !value || value.length > MAX_ID) {
			throw new Error(`Pass ${name} as an ID from the snapshot the table was read with.`);
		}
	}
	const column = request.column;
	if (
		!(typeof column === "number" && Number.isSafeInteger(column) && column >= 0 && column < 64)
		&& !(typeof column === "string" && column.length > 0 && column.length <= 256)
	) throw new Error("Pass column as an exact column title or a 0-based index below 64.");
	const value = request.value;
	if (
		!(typeof value === "string" && value.length <= MAX_VALUE)
		&& !(typeof value === "number" && Number.isFinite(value)) && typeof value !== "boolean"
	) throw new Error(`Pass value as text of at most ${MAX_VALUE} characters, a finite number or a boolean.`);
}

async function readCell(
	io: CellIO,
	request: SetCell,
	row: { element: string } | { index: number },
	column: string | number,
	signal: AbortSignal,
): Promise<TableCell> {
	const data = await io.table(
		{ pid: request.pid, window: request.window, snapshot: request.snapshot, element: request.table },
		signal,
	);
	if (!Array.isArray(data.elements)) throw new Error("The native table read returned an unsupported response.");
	return locateCell(data.elements as TableElement[], row, column);
}

/** Whether the control reads back as the written value; a date or other text set_value already read back itself. */
function written(control: NonNullable<TableCell["control"]>, value: string | number | boolean, text: string | null) {
	// The native read cuts each field to 512 characters.
	if (text !== null) return control.value === text.slice(0, 512);
	if (typeof value === "boolean") return ["1", "true"].includes(control.value) === value;
	if (typeof value === "number") return control.value.trim() !== "" && Number(control.value) === value;
	return true;
}

/**
 * Writes one table cell through its editable control, then reads the table again with the same snapshot
 * and compares the cell, so the result is completed only when the table shows the new value.
 */
export async function setCell(io: CellIO, request: SetCell, signal: AbortSignal): Promise<DesktopResult> {
	let cell: TableCell;
	try {
		validate(request);
		cell = await readCell(io, request, { element: request.row }, request.column, signal);
	} catch (error) {
		return refused((error instanceof Error ? error.message : String(error)).slice(0, 2000));
	}
	const located = { row: cell.row, column: cell.column, column_title: cell.column_title, before: cell.text };
	const control = cell.control;
	if (!control) {
		return refused("The cell exposes no editable control, only its text.", {
			code: "CELL_NOT_EDITABLE",
			cell: located,
			hint:
				"Spreadsheets such as Numbers and Excel edit a cell in place: click the cell with desktop_click, type with desktop_insert, press enter with desktop_key, then read the table again. See the table cell recipe.",
		});
	}
	if (!control.element) {
		return refused("The scope snapshot didn't store the cell's control.", {
			code: "CELL_NOT_IN_SNAPSHOT",
			cell: located,
			hint: "Inspect again with scope set to the table, then pass that snapshot and its row ID.",
		});
	}
	let text: string | null = null;
	let action: DesktopAction;
	if (control.kind === "text") {
		if (typeof request.value === "boolean") {
			return refused("The cell holds a text control; pass the text to write.", { cell: located });
		}
		text = String(request.value);
		action = { op: "type", snapshot: request.snapshot, element: control.element, text };
	} else {
		action = { op: "set-value", snapshot: request.snapshot, element: control.element, value: request.value };
	}

	const result = await io.act(action, signal);
	let data: Json;
	try {
		data = JSON.parse(result.text) as Json;
	} catch {
		return result;
	}
	const report: Json = { ...located, control: { role: control.role, route: action.op } };
	let outcome: DesktopOutcome = result.outcome ?? "unknown";
	if (outcome !== "refused") {
		// A read never consumes the snapshot, so the table is found again from the same scope and row position.
		let readback: string;
		try {
			const after = await readCell(io, request, { index: cell.row }, cell.column, signal);
			report.after = after.text;
			readback = after.others.length !== cell.others.length
					|| after.others.some((other, index) => other !== cell.others[index])
				? "row_changed"
				: after.control && written(after.control, request.value, text)
				? "matched"
				: "differs";
		} catch (error) {
			readback = "unreadable";
			report.readback_error = (error instanceof Error ? error.message : String(error)).slice(0, 2000);
		}
		report.readback = readback;
		if (outcome === "completed" && readback !== "matched") {
			outcome = "unknown";
			const action = (data.action ?? {}) as Json;
			data.action = {
				...action,
				outcome,
				error: {
					code: "CELL_UNVERIFIED",
					message: readback === "row_changed"
						? "The table's row at that position shows different cells now, so the write can't be confirmed there; the table may have re-sorted."
						: readback === "differs"
						? "The table read back a different value in that cell; the app may have reformatted or rejected it."
						: "The table could not be read back after the write.",
					hint: "Read the table again before deciding whether to write the cell again; do not repeat it blindly.",
				},
			};
		}
	}
	data.cell = report;
	return { text: JSON.stringify(data), ...(result.image ? { image: result.image } : {}), outcome, isError: outcome !== "completed" };
}
