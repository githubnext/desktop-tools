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
	"peekaboo-sheet-window.patch",
	"peekaboo-sheet-focus.patch",
	"peekaboo-restore.patch",
	"peekaboo-title.patch",
	"peekaboo-agent-cursor.patch",
	"peekaboo-dock-exact.patch",
	"peekaboo-menubar-ax.patch",
	"peekaboo-agent-window.patch",
	"peekaboo-press.patch",
	"peekaboo-layout-keys.patch",
	"peekaboo-element-action.patch",
	"peekaboo-drag-settle.patch",
	"peekaboo-element-depth.patch",
	"peekaboo-lock-holder.patch",
	"peekaboo-focus-activation.patch",
	"peekaboo-preparation-message.patch",
	"peekaboo-sck-quarantine.patch",
	"peekaboo-dialog-path.patch",
	"peekaboo-drag-path.patch",
	"peekaboo-minimized-close-test.patch",
	"peekaboo-notification-actions.patch",
	"peekaboo-fullscreen.patch",
	"peekaboo-date-value.patch",
	"peekaboo-web-text-value.patch",
	"peekaboo-system-defined-key.patch",
	"peekaboo-row-disclosure.patch",
	"peekaboo-web-text-selection.patch",
	"peekaboo-clipboard-image-export.patch",
	"peekaboo-operation-record.patch",
	"peekaboo-input-source.patch",
	"peekaboo-attachment-insert.patch",
	"peekaboo-web-accessibility.patch",
	"peekaboo-finder-paste.patch",
	"peekaboo-secure-subrole.patch",
	"peekaboo-web-accessibility-enhanced-ui.patch",
	"peekaboo-caller-admission.patch",
	"peekaboo-clipboard-image-export-allowlist.patch",
	"peekaboo-paste-window-release.patch",
	"peekaboo-layout-shortcuts.patch",
	"peekaboo-focus-budget.patch",
	"peekaboo-cursor-readback.patch",
	"peekaboo-secure-fill.patch",
	"peekaboo-web-table-headers.patch",
	"peekaboo-web-text-markers.patch",
	"peekaboo-finder-path-bar.patch",
	"peekaboo-date-settable.patch",
	"peekaboo-close-window-server-absence.patch",
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
const checkoutPath = join(checkouts, checkout);
const git = ["git", "-C", checkoutPath];
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
		// The checkout is build scratch; an earlier revision of an existing patch leaves no valid prefix.
		console.error(
			`Restoring the native checkout at ${checkoutPath}, which matches no pinned patch prefix. Local edits there are discarded.`,
		);
		run([...git, "checkout", "--", "."]);
		run([...git, "clean", "-fdq"]);
		applied = 0;
	}
	for (const patch of patches.slice(applied)) run([...git, "apply", patch]);
	if (!isExpected()) throw new Error(`The native checkout at ${checkoutPath} differs from the pinned patch stack.`);
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

// The embedded host silently drops operations outside Peekaboo's embedded allowlist, so a new operation
// reached clients only as "not supported". Fail the build instead.
const operationList = (source: string, start: string) => {
	const from = source.indexOf(start);
	if (from < 0) throw new Error(`Cannot find ${start} in the native sources`);
	const block = source.slice(from + start.length, source.indexOf("]", from + start.length));
	return new Set([...block.matchAll(/\.(\w+)/g)].map((match) => match[1]!));
};
const policy = readFileSync(
	join(checkoutPath, "Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeOperation+Policy.swift"),
	"utf8",
);
const remote = operationList(policy, "remoteDefaultAllowlist: Set<PeekabooBridgeOperation> = [");
const excluded = operationList(policy, "remoteDefaultAllowlist.subtracting([");
const requested = operationList(
	readFileSync(join(native, "sources", "runtime", "runtime.swift"), "utf8"),
	"allowedOperations: [",
);
const dropped = [...requested].filter((name) => !remote.has(name) || excluded.has(name));
if (dropped.length) {
	throw new Error(`The embedded host would drop these allowed operations: ${dropped.join(", ")}`);
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
for (const name of ["libDesktopTools.dylib", "desktop-tools-client", "desktop-tools-app"]) {
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
	for (const name of files) {
		// Checked-out notices are read-only and copies keep that mode, so replace each one.
		rmSync(join(licenses, identity, name), { force: true });
		copyFileSync(join(source, name), join(licenses, identity, name));
	}
};
notices(root, "desktop-tools");
for (const { identity } of resolved.pins) {
	const name = dependencies.get(identity);
	if (!name) throw new Error(`The resolved native dependency ${identity} is missing`);
	notices(join(checkouts, name), identity);
}
