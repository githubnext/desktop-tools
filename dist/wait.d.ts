import { type DesktopRequest, type DesktopResult, type DesktopWait } from "./protocol.js";
/** The reads a wait polls; each call is one native process, so nothing is held between polls. */
export type WaitReads = {
    /** One ordinary read request, such as apps, windows, dialog, read or inspect. */
    observe(request: DesktopRequest, signal: AbortSignal): Promise<DesktopResult>;
    /** The native elements read: matching elements or text of one window, through Accessibility alone. */
    elements(input: Record<string, unknown>, signal: AbortSignal): Promise<Record<string, unknown>>;
};
export declare const WAIT_DEFAULT_MS = 10000;
/** Below the 60-second request timeout common MCP clients use, with room for the final inspection. */
export declare const WAIT_MAX_MS = 45000;
/** Refuses argument combinations a condition doesn't use, so a misplaced filter is never silently ignored. */
export declare function validateWait(request: DesktopWait): void;
/** Polls one read-only condition with backoff until it holds or the timeout passes. Sends no input. */
export declare function waitFor(reads: WaitReads, request: DesktopWait, abort?: AbortSignal): Promise<DesktopResult>;
