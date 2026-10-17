export declare const TABLE_ROWS_DEFAULT = 100;
export declare const TABLE_ROWS_MAX = 500;
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
    bounds: {
        x: number;
        y: number;
        width: number;
        height: number;
    };
    selected?: boolean | null;
    disclosure_level?: number | null;
    disclosing?: boolean | null;
    /** A web table lists this cell among its column headers. */
    column_header?: boolean | null;
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
    table: {
        role: string;
        label: string | null;
        element: string | null;
    };
    tables_in_scope: number;
    columns: string[] | null;
    rows: TableRow[];
    row_count: number;
    row_offset: number;
    truncation: string[];
};
export declare class TableError extends Error {
}
/** Builds a table from the scope element's subtree, whose first element is the scope. */
export declare function buildTable(elements: TableElement[], { rowOffset, maxRows }?: {
    rowOffset?: number;
    maxRows?: number;
}): Table;
export type TableCell = {
    /** The row's position among the table's rows, as `index` in a table read. */
    row: number;
    column: number;
    column_title: string | null;
    text: string;
    /** The other cells of the row, which a readback compares to tell the row hasn't moved. */
    others: string[];
    /** The cell's first editable element, or null when it shows only text. */
    control: {
        element: string | null;
        role: string;
        kind: "text" | "value";
        value: string;
    } | null;
};
/**
 * Finds one cell of the table in a scope subtree: by the row's element ID, or by its position for a readback,
 * and by a column title or 0-based index.
 */
export declare function locateCell(elements: TableElement[], row: {
    element: string;
} | {
    index: number;
}, column: string | number): TableCell;
export {};
