#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const { values } = parseArgs({
	// --native2 chose the pure Swift host while it shipped beside Peekaboo's; it is the only build now.
	options: { out: { type: "string" }, scratch: { type: "string" }, native2: { type: "boolean", default: false } },
	strict: true,
});
if (!values.out) {
	throw new Error("Usage: desktop-tools-build --out <directory> [--scratch <directory>]");
}
if (process.platform !== "darwin") throw new Error("Native desktop tools build on macOS");

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const native2 = join(root, "native2");
const out = resolve(values.out);
const scratch = resolve(values.scratch ?? join(native2, ".build"));

function spawn(command: string[], env?: NodeJS.ProcessEnv) {
	return spawnSync(command[0]!, command.slice(1), { encoding: "utf8", env: env ?? process.env });
}

function run(command: string[]) {
	const result = spawnSync(command[0]!, command.slice(1), { stdio: "inherit" });
	if (result.status !== 0) throw new Error(`Command failed: ${command.join(" ")}`);
}

const swift = spawn(["xcrun", "swift", "--version"]);
const version = /Swift version (\d+)\.(\d+)/.exec(swift.stdout ?? "");
if (
	swift.status !== 0 || !version
	|| Number(version[1]) * 100 + Number(version[2]) < 602
) throw new Error("Native desktop tools require Xcode with Swift 6.2 or newer");

mkdirSync(out, { recursive: true });
const licenses = join(out, "Licenses");
// Every artifact carries the notices of what it contains; other files in <out>/Licenses stay.
const notices = (source: string, identity: string) => {
	const files = readdirSync(source).filter((name) =>
		/^(LICENSE|LICENCE|NOTICE)([.-].*)?$/i.test(name)
	);
	if (!files.length) throw new Error(`The native dependency ${identity} has no license file`);
	mkdirSync(join(licenses, identity), { recursive: true });
	for (const name of files) {
		// Checked-out notices are read-only and copies keep that mode, so replace each one.
		rmSync(join(licenses, identity, name), { force: true });
		copyFileSync(join(source, name), join(licenses, identity, name));
	}
};

// The pure Swift host (#143) exports the C ABI in docs/embed.md and has no dependencies outside the macOS SDK.
const build = [
	"xcrun",
	"swift",
	"build",
	"--package-path",
	native2,
	"--scratch-path",
	scratch,
	"--configuration",
	"release",
	// App bundles keep any needed Swift runtime libraries in Contents/Frameworks.
	"-Xlinker",
	"-rpath",
	"-Xlinker",
	"@loader_path/../Frameworks",
];
run(build);
const located = spawn([...build, "--show-bin-path"]);
if (located.status !== 0) throw new Error("Cannot locate the native build products");
for (const name of ["libDesktopTools.dylib", "desktop-tools-client", "desktop-tools-mcp", "desktop-tools-app"]) {
	copyFileSync(join(located.stdout.trim(), name), join(out, name));
}
// Notices left in <out> by a build of the removed Peekaboo stack name code this build doesn't contain.
for (const identity of ["commander", "swift-algorithms", "swift-log", "swift-numerics"]) {
	rmSync(join(licenses, identity), { recursive: true, force: true });
}
notices(root, "desktop-tools");
// native2 links neither, but contains code ported from Peekaboo and a little from AXorcist, so MIT requires their
// notices to go with it. They were copied from the vendored Peekaboo 4.8.0 before it was removed.
notices(join(native2, "Licenses", "peekaboo"), "peekaboo");
notices(join(native2, "Licenses", "axorcist"), "axorcist");
