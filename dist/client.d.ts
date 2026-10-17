import { type DesktopRequest, type DesktopResult } from "./protocol.js";
/** Explicit paths for one signed host and client pair; nothing is discovered. */
export type DesktopConfig = {
    /** Absolute path of the signed `desktop-tools-client`. */
    client: string;
    /** Unix socket passed to `desktop_tools_start` in the host app. */
    socket: string;
    /** Host app name used in permission guidance. */
    name?: string;
    /** Agent named in the host's window label, such as "Claude"; read at each call, so it can be set later. */
    agent?: string;
};
/** `data` is the parsed final bounded `text`; image bytes stay only in `image`. */
export type DesktopClientResult = DesktopResult & {
    data: unknown;
};
export type DesktopClient = (request: DesktopRequest, signal?: AbortSignal) => Promise<DesktopClientResult>;
/**
 * Gives a host refusal its own code and hint, in place of Peekaboo's generic permission code and its advice to grant
 * a permission.
 */
export declare function hostRefusal<T extends {
    code: string;
    message: string;
    hint?: unknown;
}>(error: T): T;
/** An inspection's JSON within `limit`, keeping the containers an agent can scope into over other elements. */
export declare function boundedElements(data: Record<string, unknown>, limit?: number): string;
/** Creates a client bound to one host socket and signed client; calls are independent processes. */
export declare function createDesktop(config: DesktopConfig): DesktopClient;
