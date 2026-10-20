#!/usr/bin/env node
export declare const identifier = "dev.githubnext.desktop-tools";
/** Development builds get their own identity, nested under the release one, so they never replace its binaries. */
export declare const devIdentifier = "dev.githubnext.desktop-tools.dev";
/**
 * Builds the native products into `<out>/build` and assembles an unsigned `<out>/Desktop Tools.app`, or `Desktop Tools Dev.app` for `dev`.
 * `native2` puts the pure Swift host's runtime and client in place of native/'s (#143).
 */
export declare function assemble(out: string, scratch?: string, dev?: boolean, native2?: boolean): string;
/** Signs inside out; the client's exact identifier, the bundle's plus `.desktop-client`, is what the runtime admits. */
export declare function sign(app: string, identity: string, release: boolean): void;
