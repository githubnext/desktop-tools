/** Containers read as tables. Web tables and ARIA grids are AXTable too. */
const TABLE_ROLES = ["AXTable", "AXOutline", "AXGrid"];
export const TABLE_ROWS_DEFAULT = 100;
export const TABLE_ROWS_MAX = 500;
const MAX_COLUMNS = 64;
const MAX_CELL = 256;
/** Cell text across the returned rows, in UTF-8 bytes. */
const MAX_TEXT = 96_000;
/** How far above a table its header buttons may sit, since a scroll view draws the header outside it. */
const HEADER_REACH = 40;

/** One element of the native table read, in tree pre-order. */
export type TableElement = {
	id: string | null;
	role: string;
	depth: number;
	label?: string | null;
	value?: string | null;
	title?: string | null;
	description?: string | null;
	role_description?: string | null;
	bounds: { x: number; y: number; width: number; height: number };
	selected?: boolean | null;
	disclosure_level?: number | null;
	disclosing?: boolean | null;
};

type TableRow = {
	index: number;
	element: string | null;
	cells: string[];
	depth?: number;
	expanded?: boolean;
	selected?: true;
};

type Table = {
	table: { role: string; label: string | null; element: string | null };
	tables_in_scope: number;
	columns: string[] | null;
	rows: TableRow[];
	row_count: number;
	row_offset: number;
	truncation: string[];
};

export class TableError extends Error {}

/** The element's label, unless it is only its role description, as an unnamed cell, column or icon reports. */
function ownLabel(element: TableElement): string | null | undefined {
	return element.label?.trim() && element.label.trim() === element.role_description?.trim() ? null : element.label;
}

function text(element: TableElement): string {
	for (const piece of [element.value, element.title, ownLabel(element)]) {
		if (typeof piece === "string" && piece.trim()) return piece.trim();
	}
	return "";
}

/**
 * Finds the table in the scope element's subtree, whose first element is the scope, and its rows and columns.
 * The table is the scope itself, or the first table, outline or grid inside it.
 */
function tableLayout(elements: TableElement[]) {
	const parents: number[] = [];
	const stack: number[] = [];
	for (const [index, element] of elements.entries()) {
		while (stack.length && elements[stack.at(-1)!]!.depth >= element.depth) stack.pop();
		parents.push(stack.at(-1) ?? -1);
		stack.push(index);
	}
	const end = (index: number) => {
		let next = index + 1;
		while (next < elements.length && elements[next]!.depth > elements[index]!.depth) next++;
		return next;
	};
	const tables = elements.flatMap((element, index) => TABLE_ROLES.includes(element.role) ? [index] : []);
	const table = tables[0];
	if (table === undefined) {
		throw new TableError(
			"The scope holds no table, outline or grid. Choose the table, or the scroll area or web area that holds it, from an accessibility desktop_inspect.",
		);
	}
	const owner = (index: number) => {
		let parent = parents[index]!;
		while (parent >= 0 && !TABLE_ROLES.includes(elements[parent]!.role)) parent = parents[parent]!;
		return parent;
	};
	const tableEnd = end(table);
	const inside = Array.from({ length: tableEnd - table - 1 }, (_, offset) => table + 1 + offset);
	let rows = inside.filter((index) => elements[index]!.role === "AXRow" && owner(index) === table);
	if (!rows.length) {
		// A grid of items without rows: each child is one single-cell row.
		rows = inside.filter((index) =>
			parents[index] === table && !["AXColumn", "AXScrollBar", "AXGroup"].includes(elements[index]!.role)
		);
	}
	const truncation: string[] = [];
	const cellText = (index: number) => {
		const pieces: string[] = [];
		for (let next = index + 1; next < end(index); next++) {
			const element = elements[next]!;
			if (TABLE_ROLES.includes(element.role)) {
				next = end(next) - 1;
				continue;
			}
			// A folder's disclosure triangle reads 0 or 1; the row's expanded says the same.
			if (element.role === "AXDisclosureTriangle") continue;
			const piece = text(element);
			if (piece && !pieces.includes(piece)) pieces.push(piece);
		}
		let cell = pieces.length ? pieces.join(" ") : text(elements[index]!);
		if (!cell && elements[index]!.role === "AXImage") cell = elements[index]!.description?.trim() ?? "";
		if (cell.length > MAX_CELL) {
			cell = cell.slice(0, MAX_CELL);
			if (!truncation.includes("cell_text_limit")) truncation.push("cell_text_limit");
		}
		return cell;
	};
	/** The row's cells in column order; a row without children is its own single cell. */
	const cellsOf = (row: number) => {
		const children = inside.filter((index) => parents[index] === row);
		if (!children.length) return [row];
		if (children.length > MAX_COLUMNS && !truncation.includes("column_limit")) truncation.push("column_limit");
		return children.slice(0, MAX_COLUMNS);
	};

	let columns: string[] | null = null;
	const columnTitles = inside
		.filter((index) => parents[index] === table && elements[index]!.role === "AXColumn")
		.sort((a, b) => elements[a]!.bounds.x - elements[b]!.bounds.x)
		.map((index) => (elements[index]!.title || ownLabel(elements[index]!) || elements[index]!.description || "").trim());
	if (columnTitles.some(Boolean)) columns = columnTitles;
	const bounds = elements[table]!.bounds;
	const top = rows.length ? Math.min(...rows.map((row) => elements[row]!.bounds.y)) : bounds.y + HEADER_REACH;
	if (!columns) {
		// A scroll view draws the header row of sort buttons above its table, outside it, or at its top.
		const withinRows = new Set(rows.flatMap((row) => Array.from({ length: end(row) - row }, (_, i) => row + i)));
		const buttons = elements
			.map((element, index) => ({ element, index }))
			.filter(({ element, index }) =>
				element.role === "AXButton" && !withinRows.has(index) && owner(index) <= table
				&& element.bounds.y >= bounds.y - HEADER_REACH
				&& element.bounds.y + element.bounds.height / 2 < top
				&& element.bounds.x < bounds.x + bounds.width && element.bounds.x + element.bounds.width > bounds.x
			)
			.sort((a, b) => a.element.bounds.x - b.element.bounds.x);
		// A sorted column's button holds its sort direction as its value, so its name comes first.
		if (buttons.length) {
			columns = buttons.map(({ element }) =>
				(element.title || ownLabel(element) || element.description || text(element)).trim()
			);
		}
	}
	if (!columns && rows.length) {
		// A web table's header cells say so in their role description.
		const first = inside.filter((index) => parents[index] === rows[0]);
		if (first.length && first.every((index) => /header/i.test(elements[index]!.role_description ?? ""))) {
			columns = first.map(cellText);
			rows = rows.slice(1);
		}
	}
	if (columns && columns.length > MAX_COLUMNS) {
		columns = columns.slice(0, MAX_COLUMNS);
		if (!truncation.includes("column_limit")) truncation.push("column_limit");
	}
	columns = columns?.map((column) => column.slice(0, MAX_CELL)) ?? null;
	return { table, tables, owner, rows, columns, cellsOf, cellText, end, truncation };
}

/** Builds a table from the scope element's subtree, whose first element is the scope. */
export function buildTable(
	elements: TableElement[],
	{ rowOffset = 0, maxRows = TABLE_ROWS_DEFAULT }: { rowOffset?: number; maxRows?: number } = {},
): Table {
	const { table, tables, owner, rows, columns, cellsOf, cellText, truncation } = tableLayout(elements);
	const page = rows.slice(rowOffset, rowOffset + maxRows);
	if (rowOffset + maxRows < rows.length) truncation.push("row_limit");
	const outline = elements[table]!.role === "AXOutline";
	const listed: TableRow[] = [];
	let bytes = 0;
	for (const [position, index] of page.entries()) {
		const element = elements[index]!;
		const row: TableRow = { index: rowOffset + position, element: element.id, cells: cellsOf(index).map(cellText) };
		if (outline && typeof element.disclosure_level === "number") row.depth = element.disclosure_level;
		if (outline && typeof element.disclosing === "boolean") row.expanded = element.disclosing;
		if (element.selected === true) row.selected = true;
		bytes += Buffer.byteLength(row.cells.join(""));
		if (bytes > MAX_TEXT) {
			truncation.push("text_limit");
			break;
		}
		listed.push(row);
	}
	return {
		table: {
			role: elements[table]!.role,
			label: text(elements[table]!) || elements[table]!.description?.trim() || null,
			element: elements[table]!.id,
		},
		tables_in_scope: tables.filter((index) => owner(index) === -1).length,
		columns,
		rows: listed,
		row_count: rows.length,
		row_offset: rowOffset,
		truncation,
	};
}

/** Controls whose text a cell edit types; set_value writes the other editable roles. */
const CELL_TEXT_ROLES = ["AXTextField", "AXTextArea", "AXComboBox"];
const CELL_VALUE_ROLES = ["AXCheckBox", "AXSlider", "AXIncrementor", "AXDateTimeArea"];

export type TableCell = {
	/** The row's position among the table's rows, as `index` in a table read. */
	row: number;
	column: number;
	column_title: string | null;
	text: string;
	/** The other cells of the row, which a readback compares to tell the row hasn't moved. */
	others: string[];
	/** The cell's first editable element, or null when it shows only text. */
	control: { element: string | null; role: string; kind: "text" | "value"; value: string } | null;
};

/**
 * Finds one cell of the table in a scope subtree: by the row's element ID, or by its position for a readback,
 * and by a column title or 0-based index.
 */
export function locateCell(
	elements: TableElement[],
	row: { element: string } | { index: number },
	column: string | number,
): TableCell {
	const { rows, columns, cellsOf, cellText, end } = tableLayout(elements);
	const position = "element" in row ? rows.findIndex((index) => elements[index]!.id === row.element) : row.index;
	if (position < 0 || position >= rows.length) {
		throw new TableError(
			"element" in row
				? "The row ID is not a row of this table in the scope snapshot. Read the table again and choose a row ID from it."
				: "The table no longer has that row.",
		);
	}
	let index: number;
	if (typeof column === "number") {
		index = column;
	} else {
		const matches = columns?.flatMap((title, at) => title === column ? [at] : []) ?? [];
		if (matches.length !== 1) {
			throw new TableError(
				!columns
					? "This table has no column titles. Pass the column's 0-based index instead."
					: matches.length
					? "Several columns have that title. Pass the column's 0-based index instead."
					: `No column is titled exactly that. The columns are: ${JSON.stringify(columns)}.`,
			);
		}
		index = matches[0]!;
	}
	const cells = cellsOf(rows[position]!);
	if (!Number.isSafeInteger(index) || index < 0 || index >= cells.length) {
		throw new TableError(`That row has ${cells.length} cells; pass a column from 0 to ${cells.length - 1}.`);
	}
	const cell = cells[index]!;
	let control: TableCell["control"] = null;
	for (let next = cell; next < end(cell); next++) {
		const element = elements[next]!;
		if (next > cell && TABLE_ROLES.includes(element.role)) break;
		const kind = CELL_TEXT_ROLES.includes(element.role)
			? "text"
			: CELL_VALUE_ROLES.includes(element.role)
			? "value"
			: null;
		if (kind) {
			control = { element: element.id, role: element.role, kind, value: element.value ?? "" };
			break;
		}
	}
	return {
		row: position,
		column: index,
		column_title: columns?.[index] ?? null,
		text: cellText(cell),
		others: cells.filter((other) => other !== cell).map(cellText),
		control,
	};
}
