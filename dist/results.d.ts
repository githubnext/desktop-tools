import type { DesktopResult } from "./protocol.js";
export type Json = Record<string, unknown>;
/** The JSON object a native read returned as its text. */
export declare function parseResult(result: DesktopResult): Json;
/** An error's message, bounded so a result never carries a runaway native error. */
export declare function errorMessage(error: unknown): string;
