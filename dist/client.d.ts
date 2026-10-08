import { type DesktopRequest, type DesktopResult } from "./protocol.js";
/** Explicit paths for one signed host and client pair; nothing is discovered. */
export type DesktopConfig = {
    /** Absolute path of the signed `desktop-tools-client`. */
    client: string;
    /** Unix socket passed to `desktop_tools_start` in the host app. */
    socket: string;
    /** Host app name used in permission guidance. */
    name?: string;
};
/** `data` is the parsed final bounded `text`; image bytes stay only in `image`. */
export type DesktopClientResult = DesktopResult & {
    data: unknown;
};
export type DesktopClient = (request: DesktopRequest, signal?: AbortSignal) => Promise<DesktopClientResult>;
/** Creates a client bound to one host socket and signed client; calls are independent processes. */
export declare function createDesktop(config: DesktopConfig): DesktopClient;
