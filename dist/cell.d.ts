import type { DesktopAction, DesktopRequest, DesktopResult } from "./protocol.js";
type Json = Record<string, unknown>;
type SetCell = Extract<DesktopRequest, {
    op: "set-cell";
}>;
export type CellIO = {
    /** One native table read of the scope element in the snapshot. */
    table(input: {
        pid: number;
        window: number;
        snapshot: string;
        element: string;
    }, signal: AbortSignal): Promise<Json>;
    /** One desktop action, followed by its fresh observation. */
    act(request: DesktopAction, signal: AbortSignal): Promise<DesktopResult>;
};
/**
 * Writes one table cell through its editable control, then reads the table again with the same snapshot
 * and compares the cell, so the result is completed only when the table shows the new value.
 */
export declare function setCell(io: CellIO, request: SetCell, signal: AbortSignal): Promise<DesktopResult>;
export {};
