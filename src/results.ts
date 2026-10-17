import type { DesktopResult } from "./protocol.js";

export type Json = Record<string, unknown>;

/** The JSON object a native read returned as its text. */
export function parseResult(result: DesktopResult): Json {
	return JSON.parse(result.text) as Json;
}

/** An error's message, bounded so a result never carries a runaway native error. */
export function errorMessage(error: unknown): string {
	return (error instanceof Error ? error.message : String(error)).slice(0, 2000);
}
