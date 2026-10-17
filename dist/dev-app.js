#!/usr/bin/env node
// Builds the development app with its own identity, installs it at one fixed path, and opens it through LaunchServices.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, renameSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { assemble, sign } from "./app.js";
const root = dirname(dirname(fileURLToPath(import.meta.url)));
/** Every checkout and worktree installs here, so macOS sees one development app, never scattered copies. */
export const devApp = join(homedir(), "Library", "Application Support", "desktop-tools", "dev", "Desktop Tools Dev.app");
/** The app's own default when `DESKTOP_TOOLS_STATE` is unset. */
export const devState = join(homedir(), ".local", "state", "desktop-tools-dev");
/** The one signing identity for development builds: the environment, else the repository's Git setting. */
export function devIdentity() {
    const fromEnv = process.env.DESKTOP_TOOLS_CODESIGN_IDENTITY?.trim();
    const identity = fromEnv || spawnSync("git", ["config", "--get", "desktopTools.codesignIdentity"], { cwd: root, encoding: "utf8" }).stdout.trim();
    if (!identity) {
        throw new Error("No signing identity. Set one per Mac with `git config desktopTools.codesignIdentity <SHA-1>` " +
            "(from `security find-identity -v -p codesigning`), or set DESKTOP_TOOLS_CODESIGN_IDENTITY.");
    }
    if (identity === "-")
        throw new Error("Development builds refuse ad-hoc signing: it can't keep macOS permissions across builds.");
    return identity;
}
/** Process IDs of the development app running from the fixed path. */
function running() {
    const executable = join(devApp, "Contents", "MacOS", "desktop-tools-app");
    const listing = spawnSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" }).stdout;
    return listing
        .split("\n")
        .map((line) => line.trim().match(/^(\d+) (.*)$/))
        .filter((match) => match !== null && match[2] === executable)
        .map((match) => Number(match[1]));
}
/** Stops the development app, waiting up to five seconds. */
export function stop() {
    const pids = running();
    for (const pid of pids)
        process.kill(pid, "SIGTERM");
    const deadline = Date.now() + 5000;
    while (running().length > 0) {
        if (Date.now() > deadline)
            throw new Error(`The development app (${pids.join(", ")}) didn't quit within 5 seconds.`);
        spawnSync("sleep", ["0.2"]);
    }
    return pids;
}
/** Opens the installed development app through LaunchServices, so macOS attributes its permission checks to it. */
export function launch() {
    const state = process.env.DESKTOP_TOOLS_STATE;
    const started = Date.now();
    const result = spawnSync("open", ["-g", ...(state ? ["--env", `DESKTOP_TOOLS_STATE=${state}`] : []), devApp], { stdio: "inherit" });
    if (result.status !== 0)
        throw new Error(`Couldn't open ${devApp}`);
    // A socket left by an earlier run doesn't count; wait for this run's.
    const socket = join(state || devState, "desktop.sock");
    const fresh = () => existsSync(socket) && statSync(socket).mtimeMs >= started - 1000 && running().length > 0;
    const deadline = started + 10_000;
    while (!fresh()) {
        if (Date.now() > deadline)
            throw new Error(`The development app didn't create ${socket} within 10 seconds.`);
        spawnSync("sleep", ["0.2"]);
    }
    return state || devState;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const { values } = parseArgs({
        options: { stop: { type: "boolean", default: false }, scratch: { type: "string" }, "no-open": { type: "boolean", default: false } },
        strict: true,
    });
    if (values.stop) {
        const pids = stop();
        console.log(pids.length ? `Quit the development app (${pids.join(", ")}).` : "The development app isn't running.");
    }
    else {
        const identity = devIdentity();
        const staging = join(dirname(devApp), `staging-${process.pid}`);
        rmSync(staging, { recursive: true, force: true });
        mkdirSync(staging, { recursive: true });
        try {
            const built = assemble(staging, values.scratch && resolve(values.scratch), true);
            sign(built, identity, false);
            stop();
            rmSync(devApp, { recursive: true, force: true });
            renameSync(built, devApp);
        }
        finally {
            rmSync(staging, { recursive: true, force: true });
        }
        console.log(devApp);
        if (!values["no-open"]) {
            const state = launch();
            console.log(`Serving ${join(state, "desktop.sock")}. Use it with: DESKTOP_TOOLS_STATE=${state} node dist/mcp.js`);
        }
    }
}
