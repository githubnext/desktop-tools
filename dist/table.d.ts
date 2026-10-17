/** Containers read as tables. Web tables and ARIA grids are AXTable too. */
export declare const TABLE_ROLES: string[];
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
};
export type TableRow = {
    index: number;
    element: string | null;
    cells: string[];
    depth?: number;
    expanded?: boolean;
    selected?: true;
};
export type Table = {
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
/**
 * Builds a table from the scope element's subtree, whose first element is the scope.
 * The table is the scope itself, or the first table, outline or grid inside it.
 */
export declare function buildTable(elements: TableElement[], { rowOffset, maxRows }?: {
    rowOffset?: number;
    maxRows?: number;
}): Table;
