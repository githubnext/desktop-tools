/** Containers read as tables. Web tables and ARIA grids are AXTable too. */
export const TABLE_ROLES = ["AXTable", "AXOutline", "AXGrid"];
export const TABLE_ROWS_DEFAULT = 100;
export const TABLE_ROWS_MAX = 500;
const MAX_COLUMNS = 64;
const MAX_CELL = 256;
/** Cell text across the returned rows, in UTF-8 bytes. */
const MAX_TEXT = 96_000;
/** How far above a table its header buttons may sit, since a scroll view draws the header outside it. */
const HEADER_REACH = 40;
export class TableError extends Error {
}
function text(element) {
    for (const piece of [element.value, element.title, element.label]) {
        if (typeof piece === "string" && piece.trim())
            return piece.trim();
    }
    return "";
}
/**
 * Builds a table from the scope element's subtree, whose first element is the scope.
 * The table is the scope itself, or the first table, outline or grid inside it.
 */
export function buildTable(elements, { rowOffset = 0, maxRows = TABLE_ROWS_DEFAULT } = {}) {
    const parents = [];
    const stack = [];
    for (const [index, element] of elements.entries()) {
        while (stack.length && elements[stack.at(-1)].depth >= element.depth)
            stack.pop();
        parents.push(stack.at(-1) ?? -1);
        stack.push(index);
    }
    const end = (index) => {
        let next = index + 1;
        while (next < elements.length && elements[next].depth > elements[index].depth)
            next++;
        return next;
    };
    const tables = elements.flatMap((element, index) => TABLE_ROLES.includes(element.role) ? [index] : []);
    const table = tables[0];
    if (table === undefined) {
        throw new TableError("The scope holds no table, outline or grid. Choose the table, or the scroll area or web area that holds it, from an accessibility desktop_inspect.");
    }
    const owner = (index) => {
        let parent = parents[index];
        while (parent >= 0 && !TABLE_ROLES.includes(elements[parent].role))
            parent = parents[parent];
        return parent;
    };
    const tableEnd = end(table);
    const inside = Array.from({ length: tableEnd - table - 1 }, (_, offset) => table + 1 + offset);
    let rows = inside.filter((index) => elements[index].role === "AXRow" && owner(index) === table);
    if (!rows.length) {
        // A grid of items without rows: each child is one single-cell row.
        rows = inside.filter((index) => parents[index] === table && !["AXColumn", "AXScrollBar", "AXGroup"].includes(elements[index].role));
    }
    const truncation = [];
    const cellText = (index) => {
        const pieces = [];
        for (let next = index + 1; next < end(index); next++) {
            const element = elements[next];
            if (TABLE_ROLES.includes(element.role)) {
                next = end(next) - 1;
                continue;
            }
            const piece = text(element);
            if (piece && !pieces.includes(piece))
                pieces.push(piece);
        }
        let cell = pieces.length ? pieces.join(" ") : text(elements[index]);
        if (!cell && elements[index].role === "AXImage")
            cell = elements[index].description?.trim() ?? "";
        if (cell.length > MAX_CELL) {
            cell = cell.slice(0, MAX_CELL);
            if (!truncation.includes("cell_text_limit"))
                truncation.push("cell_text_limit");
        }
        return cell;
    };
    const cellsOf = (row) => {
        const children = inside.filter((index) => parents[index] === row);
        if (!children.length)
            return [cellText(row)];
        if (children.length > MAX_COLUMNS && !truncation.includes("column_limit"))
            truncation.push("column_limit");
        return children.slice(0, MAX_COLUMNS).map(cellText);
    };
    let columns = null;
    const columnTitles = inside
        .filter((index) => parents[index] === table && elements[index].role === "AXColumn")
        .sort((a, b) => elements[a].bounds.x - elements[b].bounds.x)
        .map((index) => (elements[index].title || elements[index].label || elements[index].description || "").trim());
    if (columnTitles.some(Boolean))
        columns = columnTitles;
    const bounds = elements[table].bounds;
    const top = rows.length ? Math.min(...rows.map((row) => elements[row].bounds.y)) : bounds.y + HEADER_REACH;
    if (!columns) {
        // A scroll view draws the header row of sort buttons above its table, outside it, or at its top.
        const withinRows = new Set(rows.flatMap((row) => Array.from({ length: end(row) - row }, (_, i) => row + i)));
        const buttons = elements
            .map((element, index) => ({ element, index }))
            .filter(({ element, index }) => element.role === "AXButton" && !withinRows.has(index) && owner(index) <= table
            && element.bounds.y >= bounds.y - HEADER_REACH
            && element.bounds.y + element.bounds.height / 2 < top
            && element.bounds.x < bounds.x + bounds.width && element.bounds.x + element.bounds.width > bounds.x)
            .sort((a, b) => a.element.bounds.x - b.element.bounds.x);
        if (buttons.length)
            columns = buttons.map(({ element }) => text(element) || (element.description ?? "").trim());
    }
    if (!columns && rows.length) {
        // A web table's header cells say so in their role description.
        const first = inside.filter((index) => parents[index] === rows[0]);
        if (first.length && first.every((index) => /header/i.test(elements[index].role_description ?? ""))) {
            columns = first.map(cellText);
            rows = rows.slice(1);
        }
    }
    if (columns && columns.length > MAX_COLUMNS) {
        columns = columns.slice(0, MAX_COLUMNS);
        if (!truncation.includes("column_limit"))
            truncation.push("column_limit");
    }
    columns = columns?.map((column) => column.slice(0, MAX_CELL)) ?? null;
    const page = rows.slice(rowOffset, rowOffset + maxRows);
    if (rowOffset + maxRows < rows.length)
        truncation.push("row_limit");
    const outline = elements[table].role === "AXOutline";
    const listed = [];
    let bytes = 0;
    for (const [position, index] of page.entries()) {
        const element = elements[index];
        const row = { index: rowOffset + position, element: element.id, cells: cellsOf(index) };
        if (outline && typeof element.disclosure_level === "number")
            row.depth = element.disclosure_level;
        if (outline && typeof element.disclosing === "boolean")
            row.expanded = element.disclosing;
        if (element.selected === true)
            row.selected = true;
        bytes += Buffer.byteLength(row.cells.join(""));
        if (bytes > MAX_TEXT) {
            truncation.push("text_limit");
            break;
        }
        listed.push(row);
    }
    return {
        table: {
            role: elements[table].role,
            label: text(elements[table]) || elements[table].description?.trim() || null,
            element: elements[table].id,
        },
        tables_in_scope: tables.filter((index) => owner(index) === -1).length,
        columns,
        rows: listed,
        row_count: rows.length,
        row_offset: rowOffset,
        truncation,
    };
}
