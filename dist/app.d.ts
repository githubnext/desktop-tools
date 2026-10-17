#!/usr/bin/env node
export declare const identifier = "dev.githubnext.desktop-tools";
/** Development builds get their own identity, nested under the release one, so they never replace its binaries. */
export declare const devIdentifier = "dev.githubnext.desktop-tools.dev";
/** Builds the native products into `<out>/build` and assembles an unsigned `<out>/Desktop Tools.app`, or `Desktop Tools Dev.app` for `dev`. */
export declare function assemble(out: string, scratch?: string, dev?: boolean): string;
/** Signs inside out; the client's exact identifier, the bundle's plus `.desktop-client`, is what the runtime admits. */
export declare function sign(app: string, identity: string, release: boolean): void;
