import { type DesktopRequest } from "./protocol.js";
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
 * `app` names the signed app that holds the macOS permissions, whose menu pauses input.
 */
export declare function desktopToolRules(app: string): string[];
export declare function desktopTools({ place, app }: {
    place: string;
    app: string;
}): DesktopTool[];
/** The request for one call; exclusive argument forms that schemas cannot state are checked here. */
export declare function desktopRequest(tool: DesktopTool, args: Record<string, unknown>): DesktopRequest;
