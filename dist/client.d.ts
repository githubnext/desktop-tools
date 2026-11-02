import type { DesktopRequest, DesktopResult } from "./protocol.js";
/** Explicit paths for one signed host and client pair; nothing is discovered. */
export type DesktopConfig = {
    /** Absolute path of the signed `desktop-tools-client`, the one bundled in the host app. */
    client: string;
    /** Unix socket passed to `desktop_tools_start` in the host app. */
    socket: string;
    /** Host app name used in permission guidance. */
    name?: string;
    /** Agent named in the host's window label, such as "Claude"; read at each call, so it can be set later. */
    agent?: string;
    /**
     * Return results whole, with detection metadata, timings, receipts and every window, instead of the compact shape
     * written for models. Defaults to `DESKTOP_TOOLS_VERBOSE=1` in the environment.
     */
    verbose?: boolean;
    /**
     * Ignored. The Swift host's wire, which this option once chose, is the only one since the Peekaboo stack was
     * removed; it stays so configs that pass `wire: 2` still type-check.
     */
    wire?: 2;
};
/** `data` is the parsed final `text`; image bytes stay only in `image`. */
export type DesktopClientResult = DesktopResult & {
    data: unknown;
};
export type DesktopClient = (request: DesktopRequest, signal?: AbortSignal) => Promise<DesktopClientResult>;
/**
 * Creates a client bound to one host socket and signed client. Each request goes whole to the client as one tool call,
 * `desktop_` and its op, and the tool result comes back as the MCP server would send it: the host checks the arguments
 * and compacts the result.
 */
export declare function createDesktop(config: DesktopConfig): DesktopClient;
