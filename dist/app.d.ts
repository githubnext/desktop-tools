#!/usr/bin/env node
export declare const identifier = "dev.githubnext.desktop-tools";
/** Builds the native products into `<out>/build` and assembles an unsigned `<out>/Desktop Tools.app`. */
export declare function assemble(out: string, scratch?: string): string;
/** Signs inside out; the client's exact identifier is what the runtime admits. */
export declare function sign(app: string, identity: string, release: boolean): void;
