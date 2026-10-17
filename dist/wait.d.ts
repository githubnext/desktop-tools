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
/** An action's expect polls briefly by default; input that took effect usually shows within a few seconds. */
export declare const EXPECT_DEFAULT_MS = 3000;
export declare const EXPECT_MAX_MS = 10000;
/** Refuses argument combinations a condition doesn't use, so a misplaced filter is never silently ignored. */
export declare function validateWait(request: DesktopWait, maxTimeout?: number): void;
/** Polls one read-only condition with backoff until it holds or the timeout passes. Sends no input. */
export declare function waitFor(reads: WaitReads, request: DesktopWait, abort?: AbortSignal): Promise<DesktopResult>;
/** The condition an action's expect names: desktop_wait's arguments without op, with a shorter timeout. */
export declare function validateExpect(expect: unknown): DesktopWait;
/** Input the expectation follows: one action call, which runs at most once. */
export type ExpectedAction = (signal?: AbortSignal) => Promise<DesktopResult>;
/**
 * Runs an action once, and when its outcome is unknown, polls the expected condition for a short time.
 * The condition is read before input and must not already hold, so a later match shows the input's effect;
 * the outcome becomes completed only on that match. Input is never repeated.
 */
export declare function expectAfter(reads: WaitReads, expect: DesktopWait, act: ExpectedAction, abort?: AbortSignal): Promise<DesktopResult>;
