#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const { values } = parseArgs({
	options: { out: { type: "string" }, scratch: { type: "string" } },
	strict: true,
});
if (!values.out) {
	throw new Error("Usage: desktop-tools-build --out <directory> [--scratch <directory>]");
}
if (process.platform !== "darwin") throw new Error("Native desktop tools build on macOS");

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const native = join(root, "native");
const out = resolve(values.out);
const scratch = resolve(values.scratch ?? join(native, ".build"));
const revision = "4d43dc9d80cd2aa3787a27f54b76d692db1dcf8f";
// Later patches may change earlier patch contexts, so this order is part of the pinned source.
const patches = [
	"peekaboo-click.patch",
	"peekaboo-insert.patch",
	"peekaboo-pointer-window.patch",
	"peekaboo-quit.patch",
	"peekaboo-clipboard-text.patch",
	"peekaboo-close.patch",
	"peekaboo-clipboard-image.patch",
	"peekaboo-launch.patch",
	"peekaboo-clipboard-files.patch",
	"peekaboo-point-focus.patch",
	"peekaboo-clipboard-image-write.patch",
	"peekaboo-open.patch",
	"peekaboo-menu.patch",
	"peekaboo-clipboard-files-write.patch",
	"peekaboo-stale-click.patch",
].map((name) => join(native, "patches", name));

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

const package_ = ["--package-path", native, "--scratch-path", scratch];
run(["xcrun", "swift", "package", ...package_, "--force-resolved-versions", "resolve"]);
const resolved = JSON.parse(readFileSync(join(native, "Package.resolved"), "utf8")) as {
	pins: { identity: string; state: { version: string; revision: string } }[];
};
const checkouts = join(scratch, "checkouts");
const dependencies = new Map(readdirSync(checkouts).map((name) => [name.toLowerCase(), name]));
const peekaboo = resolved.pins.find(({ identity }) => identity === "peekaboo");
if (peekaboo?.state.version !== "4.8.0" || peekaboo.state.revision !== revision) {
	throw new Error("The native patches require Peekaboo 4.8.0 at its pinned revision");
}
const checkout = dependencies.get("peekaboo");
if (!checkout) throw new Error("The resolved Peekaboo checkout is missing");
const git = ["git", "-C", join(checkouts, checkout)];
const head = spawn([...git, "rev-parse", "HEAD"]);
if (head.status !== 0 || head.stdout.trim() !== revision) {
	throw new Error(`The Peekaboo checkout must be at ${revision} before applying the patches`);
}

// Assemble the expected stack in a private index, then apply only the missing suffix.
const temporary = mkdtempSync(join(tmpdir(), "desktop-tools-patches-"));
try {
	const env = { ...process.env, GIT_INDEX_FILE: join(temporary, "index") };
	const initial = spawn([...git, "read-tree", "HEAD"], env);
	if (initial.status !== 0) throw new Error("Cannot read the pinned native tree: " + initial.stderr);
	const isExpected = () => {
		const extra = spawn([...git, "ls-files", "--others", "--exclude-standard"], env);
		const diff = spawn([...git, "diff", "--quiet", "--"], env);
		if (extra.status !== 0 || (diff.status !== 0 && diff.status !== 1)) {
			throw new Error("Cannot verify the native checkout: " + extra.stderr + "\n" + diff.stderr);
		}
		return !extra.stdout.trim() && diff.status === 0;
	};
	let applied = -1;
	for (let index = 0; index <= patches.length; index++) {
		if (isExpected()) applied = index;
		if (index === patches.length) break;
		const expected = spawn([...git, "apply", "--cached", patches[index]!], env);
		if (expected.status !== 0) {
			throw new Error("Cannot assemble the pinned native patch stack: " + expected.stderr);
		}
	}
	if (applied < 0) {
		throw new Error(
			"The native checkout differs from every pinned patch prefix. Resolve source drift before building.",
		);
	}
	for (const patch of patches.slice(applied)) run([...git, "apply", patch]);
	if (!isExpected()) throw new Error("The native checkout differs from the pinned patch stack.");
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

const build = [
	"xcrun",
	"swift",
	"build",
	...package_,
	"--configuration",
	"release",
	"--force-resolved-versions",
	// App bundles keep any needed Swift runtime libraries in Contents/Frameworks.
	"-Xlinker",
	"-rpath",
	"-Xlinker",
	"@loader_path/../Frameworks",
];
run(build);
const location = spawn([...build, "--show-bin-path"]);
if (location.status !== 0) throw new Error("Cannot locate the native build products");
const products = location.stdout.trim();
mkdirSync(out, { recursive: true });
for (const name of ["libDesktopTools.dylib", "desktop-tools-client"]) {
	copyFileSync(join(products, name), join(out, name));
}

// Every artifact carries the notices of what it links; other files in <out>/Licenses stay.
const licenses = join(out, "Licenses");
const notices = (source: string, identity: string) => {
	const files = readdirSync(source).filter((name) =>
		/^(LICENSE|LICENCE|NOTICE)([.-].*)?$/i.test(name)
	);
	if (!files.length) throw new Error(`The native dependency ${identity} has no license file`);
	mkdirSync(join(licenses, identity), { recursive: true });
	for (const name of files) copyFileSync(join(source, name), join(licenses, identity, name));
};
notices(root, "desktop-tools");
for (const { identity } of resolved.pins) {
	const name = dependencies.get(identity);
	if (!name) throw new Error(`The resolved native dependency ${identity} is missing`);
	notices(join(checkouts, name), identity);
}
