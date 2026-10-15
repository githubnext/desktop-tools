import type { DesktopRequest } from "./protocol.js";
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
 * The desktop tools every host offers agents. `place` names where they act, as in "this Mac";
 * `app` names the signed app that holds the macOS permissions and runs the native service.
 */
export declare function desktopTools({ place, app }: {
    place: string;
    app: string;
}): DesktopTool[];
/** The request for one call; exclusive argument forms that schemas cannot state are checked here. */
export declare function desktopRequest(tool: DesktopTool, args: Record<string, unknown>): DesktopRequest;
