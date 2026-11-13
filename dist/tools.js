// The desktop tools as embedders such as Ace offer them. Their descriptions, schemas and shared rules are declared in
// native2/Sources/DesktopProtocol/ContractTools.swift, which the app's MCP server serves; scripts/contract.mjs exports
// them into contract.ts.
import { contract } from "./contract.js";
/** desktop_read's table paging: rows per page by default, and at most. */
export const TABLE_ROWS_DEFAULT = contract.limits.tableRowsDefault;
export const TABLE_ROWS_MAX = contract.limits.tableRowsMax;
/** desktop_wait's timeout_ms, and an action's expect.timeout_ms: default and maximum. */
export const WAIT_DEFAULT_MS = contract.limits.waitDefaultMS;
export const WAIT_MAX_MS = contract.limits.waitMaxMS;
export const EXPECT_DEFAULT_MS = contract.limits.expectDefaultMS;
export const EXPECT_MAX_MS = contract.limits.expectMaxMS;
/** A copy of `value` with `{{place}}` and `{{app}}` replaced in every string. */
function substitute(value, names) {
    if (typeof value === "string")
        return value.replaceAll("{{place}}", names.place).replaceAll("{{app}}", names.app);
    if (Array.isArray(value))
        return value.map((item) => substitute(item, names));
    if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item, names)]));
    }
    return value;
}
/**
 * Rules every desktop tool shares, which the tool descriptions don't repeat; a host's agent guidance should include them.
 * `app` names the signed app that holds the macOS permissions, whose menu pauses input. The second argument is ignored;
 * it once chose the Peekaboo stack's rules.
 */
export function desktopToolRules(app, _wire) {
    return substitute([...contract.rules], { place: "", app });
}
/**
 * The desktop tools every host offers agents. `place` names where they act, as in "this Mac";
 * `app` names the signed app that holds the macOS permissions and runs the native service.
 * `wire` is ignored; it once chose the Peekaboo stack's text.
 */
export function desktopTools({ place, app }) {
    return contract.tools.map(({ name, op, description, parameters }) => substitute({ name, op, description, parameters: parameters }, { place, app }));
}
/**
 * The request for one call: the tool's op and the arguments its schema names. The host checks every argument, including
 * the exclusive forms a schema can't state, and refuses a bad one with the same text this once threw.
 */
export function desktopRequest(tool, args) {
    const request = { op: tool.op };
    for (const key of Object.keys(tool.parameters.properties)) {
        if (args[key] !== undefined)
            request[key] = args[key];
    }
    return request;
}
