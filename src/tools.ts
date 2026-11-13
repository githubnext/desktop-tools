// The desktop tools as embedders such as Ace offer them. Their descriptions, schemas and shared rules are declared in
// native2/Sources/DesktopProtocol/ContractTools.swift, which the app's MCP server serves; scripts/contract.mjs exports
// them into contract.ts.
import { contract } from "./contract.js";
import type { DesktopRequest } from "./protocol.js";

/** desktop_read's table paging: rows per page by default, and at most. */
export const TABLE_ROWS_DEFAULT = contract.limits.tableRowsDefault;
export const TABLE_ROWS_MAX = contract.limits.tableRowsMax;
/** desktop_wait's timeout_ms, and an action's expect.timeout_ms: default and maximum. */
export const WAIT_DEFAULT_MS = contract.limits.waitDefaultMS;
export const WAIT_MAX_MS = contract.limits.waitMaxMS;
export const EXPECT_DEFAULT_MS = contract.limits.expectDefaultMS;
export const EXPECT_MAX_MS = contract.limits.expectMaxMS;

export type JsonSchema = { [key: string]: unknown };

export type DesktopTool = {
	name: string;
	op: DesktopRequest["op"];
	description: string;
	/** JSON Schema for the tool's arguments; its properties are the request's fields besides `op`. */
	parameters: JsonSchema;
};

/** A copy of `value` with `{{place}}` and `{{app}}` replaced in every string. */
function substitute<T>(value: T, names: { place: string; app: string }): T {
	if (typeof value === "string") return value.replaceAll("{{place}}", names.place).replaceAll("{{app}}", names.app) as T;
	if (Array.isArray(value)) return value.map((item) => substitute(item, names)) as T;
	if (value && typeof value === "object") {
		return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item, names)])) as T;
	}
	return value;
}

/**
 * Rules every desktop tool shares, which the tool descriptions don't repeat; a host's agent guidance should include them.
 * `app` names the signed app that holds the macOS permissions, whose menu pauses input. The second argument is ignored;
 * it once chose the Peekaboo stack's rules.
 */
export function desktopToolRules(app: string, _wire?: 2): string[] {
	return substitute([...contract.rules], { place: "", app });
}

/**
 * The desktop tools every host offers agents. `place` names where they act, as in "this Mac";
 * `app` names the signed app that holds the macOS permissions and runs the native service.
 * `wire` is ignored; it once chose the Peekaboo stack's text.
 */
export function desktopTools({ place, app }: { place: string; app: string; wire?: 2 }): DesktopTool[] {
	return contract.tools.map(({ name, op, description, parameters }) =>
		substitute({ name, op, description, parameters: parameters as JsonSchema }, { place, app })
	);
}

/**
 * The request for one call: the tool's op and the arguments its schema names. The host checks every argument, including
 * the exclusive forms a schema can't state, and refuses a bad one with the same text this once threw.
 */
export function desktopRequest(tool: DesktopTool, args: Record<string, unknown>): DesktopRequest {
	const request: Record<string, unknown> = { op: tool.op };
	for (const key of Object.keys(tool.parameters.properties as JsonSchema)) {
		if (args[key] !== undefined) request[key] = args[key];
	}
	return request as DesktopRequest;
}
