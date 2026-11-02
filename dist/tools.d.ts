import { type DesktopRequest } from "./protocol.js";
/** desktop_read's table paging: rows per page by default, and at most. */
export declare const TABLE_ROWS_DEFAULT = 100;
export declare const TABLE_ROWS_MAX = 500;
/** desktop_wait's timeout_ms, and an action's expect.timeout_ms: default and maximum. */
export declare const WAIT_DEFAULT_MS = 10000;
export declare const WAIT_MAX_MS = 45000;
export declare const EXPECT_DEFAULT_MS = 3000;
export declare const EXPECT_MAX_MS = 10000;
export type JsonSchema = {
    [key: string]: unknown;
};
export type DesktopTool = {
    name: string;
    op: DesktopRequest["op"];
    description: string;
    /** JSON Schema for the tool's arguments; its properties are the request's fields besides `op`. */
    parameters: JsonSchema;
};
/**
 * Rules every desktop tool shares, which the tool descriptions don't repeat; a host's agent guidance should include them.
 * `app` names the signed app that holds the macOS permissions, whose menu pauses input. Launching and opening stay in the
 * background unless asked to activate (#162). The second argument is ignored; it once chose the Peekaboo stack's rules.
 */
export declare function desktopToolRules(app: string, _wire?: 2): string[];
/**
 * The desktop tools every host offers agents. `place` names where they act, as in "this Mac";
 * `app` names the signed app that holds the macOS permissions and runs the native service.
 * `wire` is ignored; it once chose the Peekaboo stack's text.
 */
export declare function desktopTools({ place, app }: {
    place: string;
    app: string;
    wire?: 2;
}): DesktopTool[];
/** The request for one call; exclusive argument forms that schemas cannot state are checked here. */
export declare function desktopRequest(tool: DesktopTool, args: Record<string, unknown>): DesktopRequest;
