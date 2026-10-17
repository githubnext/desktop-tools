#!/usr/bin/env node
/** Every checkout and worktree installs here, so macOS sees one development app, never scattered copies. */
export declare const devApp: string;
/** The app's own default when `DESKTOP_TOOLS_STATE` is unset. */
export declare const devState: string;
/** The one signing identity for development builds: the environment, else the repository's Git setting. */
export declare function devIdentity(): string;
/** Stops the development app, waiting up to five seconds. */
export declare function stop(): number[];
/** Opens the installed development app through LaunchServices, so macOS attributes its permission checks to it. */
export declare function launch(): string;
